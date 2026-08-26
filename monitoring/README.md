# Monitoring

Three ways to get an operations dashboard, in increasing order of cost.

| Option | Cost | Requires | Use when |
|---|---|---|---|
| **Terminal dashboard** | $0 | kubectl | Any cluster, including kind. Instant. |
| **Local Prometheus + Grafana** | $0 | kind + Helm | You want real dashboards without GCP |
| **Cloud Monitoring** | free tier, then per-sample | GKE + Managed Prometheus | Real GKE operations |

> ⚠️ **Status: the Cloud Monitoring dashboard and alert policies in this
> directory have NOT been imported into a live GCP project.** They are
> schema-shaped and reviewed, but untested against the real API — because the
> target project's billing account was closed at the time of writing. Treat them
> as a starting point, expect to adjust metric filters, and see
> [VALIDATION_REPORT.md](../VALIDATION_REPORT.md).

---

## Option 1 — Terminal dashboard ($0, works anywhere)

```bash
./monitoring/ops-dashboard.sh -n orders
./monitoring/ops-dashboard.sh -n orders --watch     # refresh every 10s
```

Covers cluster health, replica counts, restarts, HPA state, endpoints, resource
usage, the running version, and a live error-rate sample. No dependencies beyond
`kubectl`, no cost, and it works identically on kind and GKE.

---

## Option 2 — Prometheus + Grafana on kind ($0)

Real dashboards, real PromQL, no cloud account.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prom prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.retention=6h

# Tell Prometheus to scrape orders-api
helm upgrade orders-api ./helm/application \
  -f helm/application/values.yaml -f helm/application/values-local.yaml \
  -n orders --set monitoring.serviceMonitor.enabled=true

kubectl port-forward -n monitoring svc/kube-prom-grafana 3000:80
# http://localhost:3000  (admin / admin)
```

Useful PromQL against this app's metrics:

```promql
# Request rate by status
sum by (status) (rate(http_requests_total{namespace="orders"}[5m]))

# 5xx error rate as a percentage  ← the important one
100 * sum(rate(http_requests_total{namespace="orders",status=~"5.."}[5m]))
    / sum(rate(http_requests_total{namespace="orders"}[5m]))

# p95 latency
histogram_quantile(0.95,
  sum by (le) (rate(http_request_duration_seconds_bucket{namespace="orders"}[5m])))

# Running versions — more than one means a MIXED FLEET
count by (version) (app_build_info{namespace="orders"})

# Ready pods
sum(app_ready{namespace="orders"})
```

> ⚠️ `kube-prometheus-stack` is heavy for a laptop (Prometheus, Grafana,
> Alertmanager, node-exporter, kube-state-metrics). On a small machine, use
> Option 1 instead.

---

## Option 3 — Google Cloud Monitoring

### Prerequisites — these cost money

```hcl
# terraform/environments/dev/terraform.tfvars
enable_managed_prometheus = true    # billed per sample beyond the free allowance
```

```yaml
# helm/application/values-dev.yaml
monitoring:
  podMonitoring:
    enabled: true
```

Without both, the application-metric panels (request rate, error rate, latency,
version) render empty. The cluster-level panels (nodes, CPU, memory, restarts)
work regardless — those metrics ship for free with GKE.

### Import the dashboard

```bash
gcloud monitoring dashboards create \
  --config-from-file=monitoring/dashboards/gke-operations-dashboard.json \
  --project PROJECT_ID

gcloud monitoring dashboards list --project PROJECT_ID
```

To update an existing dashboard, get its name first:

```bash
gcloud monitoring dashboards list --project PROJECT_ID --format='value(name)'
gcloud monitoring dashboards update DASHBOARD_ID \
  --config-from-file=monitoring/dashboards/gke-operations-dashboard.json
```

### Create the alert policies

```bash
for f in monitoring/alerts/*.json; do
  echo "creating $f"
  gcloud alpha monitoring policies create --policy-from-file="$f" --project PROJECT_ID
done

gcloud alpha monitoring policies list --project PROJECT_ID
```

### Notification channels

An alert policy with no notification channel fires into the void. Create the
channel, then attach it.

```bash
gcloud alpha monitoring channels create \
  --display-name="oncall-email" \
  --type=email \
  --channel-labels=email_address=you@example.com \
  --project PROJECT_ID

gcloud alpha monitoring channels list --project PROJECT_ID --format='value(name)'

# Attach to every policy
for p in $(gcloud alpha monitoring policies list --project PROJECT_ID --format='value(name)'); do
  gcloud alpha monitoring policies update "$p" \
    --set-notification-channels=CHANNEL_NAME --project PROJECT_ID
done
```

### Log-based metrics

`deployment-failure.json` depends on a log-based metric. Create it first:

```bash
gcloud logging metrics create k8s_pod_failure_events \
  --description="Pod failure events (scheduling, image pull, crash loop)" \
  --log-filter='resource.type="k8s_pod"
                jsonPayload.reason=("FailedScheduling" OR "BackOff" OR "Failed" OR "FailedCreate")' \
  --project PROJECT_ID
```

This pattern — a log query becomes a metric becomes an alert — is how you alert
on things that have no native metric. It's also how you'd alert on 5xx without
paying for Managed Prometheus:

```bash
gcloud logging metrics create orders_api_5xx \
  --description="orders-api 5xx responses" \
  --log-filter='resource.type="k8s_container"
                resource.labels.namespace_name="orders"
                jsonPayload.status>=500' \
  --project PROJECT_ID
```

### Tear down

Dashboards and alert policies are free to keep. **Managed Prometheus is not** —
turn it off when you're done:

```bash
# in terraform.tfvars
enable_managed_prometheus = false
```

---

## The eight alerts

| Alert | Threshold | Severity | Catches |
|---|---|---|---|
| [high-5xx-rate](alerts/high-5xx-rate.json) | >1% for 2 min | CRITICAL | **Green pods, failing requests** — nothing else catches this |
| [unavailable-replicas](alerts/unavailable-replicas.json) | < desired for 5 min | CRITICAL | Degraded or zero capacity |
| [node-problem](alerts/node-problem.json) | NotReady 5 min | CRITICAL | Node failure, Spot preemption |
| [high-latency](alerts/high-latency.json) | p95 > 1s for 5 min | WARNING | Slow deploys, CPU throttling, slow dependency |
| [memory-pressure](alerts/memory-pressure.json) | >85% of limit 5 min | WARNING | **Fires before the OOMKill** |
| [pod-restarts](alerts/pod-restarts.json) | >2 in 10 min | WARNING | Crash loops, OOM, liveness failures |
| [high-cpu](alerts/high-cpu.json) | >80% of request 10 min | WARNING | HPA not keeping up, or not working |
| [deployment-failure](alerts/deployment-failure.json) | any failure event | WARNING | Stuck rollouts |

Every policy carries a `documentation` block with the **first command to run**
and the investigation path. An alert that says "CPU is high" and nothing else
wastes the responder's first five minutes.

### Why these thresholds

- **5xx at 1% / 2 min** — tight, because this is the alert that catches
  user-facing breakage. In this project's own rollback drill, the detection gap
  was 11 minutes with a 5-minute window; 2 minutes closes most of that.
- **Memory at 85%, not 100%** — alerting on an OOMKill tells you about an outage
  you failed to prevent. 85% gives you time to act.
- **Restarts as a *rate*, not a count** — a cumulative count alerts forever after
  one historical restart, and then gets muted, and then you have no alert.
- **CPU at 10 minutes** — deliberately slow. A brief CPU spike that the HPA
  absorbs is the system working, not an incident.

---

## What to alert on, and what not to

**Alert on symptoms users feel:** error rate, latency, availability.
**Not on causes:** CPU is high, a pod restarted, disk is 70% full.

A pod restarting at 03:00 that the system healed automatically is not worth
waking someone for. A 5xx rate of 3% is — even if every pod is Ready and every
CPU graph is flat.

This is the whole lesson of [docs/INCIDENT_HTTP_500.md](../docs/INCIDENT_HTTP_500.md):
Kubernetes health tells you whether the *platform* is happy. Only request-level
metrics tell you whether *users* are being served.

Read [DASHBOARD_GUIDE.md](DASHBOARD_GUIDE.md) for what each panel means during a
real incident.

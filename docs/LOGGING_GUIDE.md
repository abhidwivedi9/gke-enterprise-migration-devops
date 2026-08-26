# Logging Guide

Two tools, two different jobs:

| | `kubectl logs` | Cloud Logging |
|---|---|---|
| **Scope** | Pods that exist **right now** | Everything, including deleted pods |
| **Retention** | Until the pod is deleted | 30 days default |
| **Speed** | Instant | A few seconds |
| **Query** | grep | Structured field queries, across the fleet |
| **Use for** | Live triage | Investigation, correlation, history |

Rule of thumb: **`kubectl logs` while it's happening, Cloud Logging afterwards.**

---

## Part 1 — `kubectl logs`

### The commands, and when each is right

```bash
# One pod
kubectl logs POD -n orders

# Follow live — during a deploy, or while reproducing
kubectl logs -f POD -n orders

# THE CRASH-DEBUGGING COMMAND
kubectl logs POD -n orders --previous
```

> **`--previous` is the one that matters.** For a `CrashLoopBackOff`, the
> *current* container has only just started and hasn't failed yet. The reason it
> died is in the *previous* container. This single flag is the difference
> between a 2-minute diagnosis and an hour of confusion.
>
> It holds only the **last** terminated container. A second restart overwrites
> it — so capture it immediately.

```bash
# ALL pods of the service at once - what you usually want
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=100

# ...with pod names prefixed, so you can tell them apart
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --prefix --tail=100

# Time-bounded
kubectl logs POD -n orders --since=15m
kubectl logs POD -n orders --since-time=2026-08-26T13:50:00Z

# Timestamps (the app emits its own, but useful for non-JSON output)
kubectl logs POD -n orders --timestamps

# Multi-container pods
kubectl logs POD -n orders -c orders-api
kubectl logs POD -n orders --all-containers
```

### Slicing structured logs

Because this app emits one JSON object per line, `jq` turns `kubectl logs` into
a query tool:

```bash
K="kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=1000"

# Errors only
$K | jq -c 'select(.severity=="ERROR")'

# All 5xx responses
$K | jq -c 'select(.status >= 500) | {timestamp, path, status, request_id, pod}'

# WHICH POD is failing? One pod vs all pods is a fork in the diagnosis.
$K | jq -r 'select(.status >= 500) | .pod' | sort | uniq -c

# Which endpoints?
$K | jq -r 'select(.status >= 500) | .path' | sort | uniq -c | sort -rn

# Slowest requests
$K | jq -c 'select(.latency_ms > 500) | {path, latency_ms, request_id}'

# Follow one request end to end
$K | jq -c 'select(.request_id=="25c049a2-1819-40e3-b1ba-39fea3655f2f")'

# Which versions are actually serving? (mixed fleet detector)
$K | jq -r '.version' | sort | uniq -c

# Error rate over the sample
$K | jq -s 'group_by(.status >= 500) | map({errors: (.[0].status >= 500), n: length})'
```

### The three commands you'll actually use most

```bash
kubectl logs POD -n orders --previous          # why did it crash?
kubectl describe pod POD -n orders             # what does Kubernetes think?
kubectl get events -n orders --sort-by=.lastTimestamp | tail -20   # what changed?
```

### `describe` and events

Logs are the *application's* view. Events are *Kubernetes'* view. For scheduling,
image pulls, probes and evictions, the answer is in events — there may be no
container, and therefore no logs, at all.

```bash
kubectl describe pod POD -n orders

# The four sections worth reading first:
kubectl describe pod POD -n orders | grep -A6 "Last State"     # why it died
kubectl describe pod POD -n orders | grep -A8 "Events"         # what happened
kubectl describe pod POD -n orders | grep -A5 "Readiness"      # probe config
kubectl describe pod POD -n orders | grep -A4 "Limits"         # resources
```

```bash
# Events
kubectl get events -n orders --sort-by=.lastTimestamp
kubectl get events -n orders --field-selector type=Warning
kubectl get events -n orders --field-selector involvedObject.name=POD
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -30
```

> ⚠️ **Events are garbage-collected after ~1 hour.** If an incident is older than
> that, events are gone and Cloud Logging is your only option. Capture them
> during the incident:
> ```bash
> ./scripts/collect-logs.sh -n orders
> ```

---

## Part 2 — Cloud Logging

### Why structured logging is the whole game

The app emits:

```json
{"severity":"INFO","message":"GET /api/orders 200","timestamp":"2026-08-26T18:17:28.580Z",
 "service":"orders-api","version":"2.4.17","commit":"000000000000",
 "pod":"orders-api-cdf4ff75b-2kwjd","namespace":"orders",
 "request_id":"25c049a2-1819-40e3-b1ba-39fea3655f2f","path":"/api/orders",
 "status":200,"latency_ms":1.1,"method":"GET"}
```

Cloud Logging parses each key into an **indexed, queryable field**. That's the
difference between `jsonPayload.status>=500` (instant, precise) and grepping
free text (slow, approximate).

Plain-text logs — `2026-08-26 ERROR something failed` — arrive as one opaque
string. You cannot query them by status, version, or pod. **Structured logging
is not a nicety; it's what makes the next three sections possible.**

### The console

`https://console.cloud.google.com/logs/query?project=PROJECT_ID`

```bash
# Or from the CLI
gcloud logging read 'resource.type="k8s_container"' --limit 50 --format json
```

### Queries by scope

```
# Everything from this container
resource.type="k8s_container"
resource.labels.cluster_name="orders-api-dev-gke"
resource.labels.namespace_name="orders"
resource.labels.container_name="orders-api"

# One specific pod
resource.labels.pod_name="orders-api-cdf4ff75b-2kwjd"

# One deployment (label-based, survives pod churn)
labels."k8s-pod/app_kubernetes_io/instance"="orders-api"
```

### Queries by severity

```
severity>=ERROR
severity=WARNING
severity>=ERROR AND resource.labels.namespace_name="orders"
```

### Queries by time

```
timestamp >= "2026-08-26T13:50:00Z" AND timestamp <= "2026-08-26T14:15:00Z"

# Relative
timestamp >= "2026-08-26T13:00:00Z"
```

Or in the console's time-range picker — faster, and it applies to any query.

### The queries that earn their keep

```
# 1. All 5xx from the service
resource.type="k8s_container"
resource.labels.namespace_name="orders"
jsonPayload.status>=500

# 2. ONE REQUEST, end to end. If you propagate request_id across services,
#    this becomes a poor-man's distributed trace.
jsonPayload.request_id="25c049a2-1819-40e3-b1ba-39fea3655f2f"

# 3. Did errors start with a specific version? The correlation question.
resource.type="k8s_container"
jsonPayload.severity="ERROR"
jsonPayload.version="2.4.17"

# 4. Slow requests
jsonPayload.latency_ms>1000

# 5. Errors on one endpoint
jsonPayload.path="/api/orders"
jsonPayload.status>=500

# 6. Application startup lines - which versions started, and when
jsonPayload.message=~"started: version="

# 7. Crash / OOM evidence at the platform layer
resource.type="k8s_container"
severity>=ERROR
textPayload=~"OOMKilled|CrashLoopBackOff|Back-off"

# 8. Kubernetes EVENTS, retained far longer than kubectl keeps them
logName="projects/PROJECT_ID/logs/events"
jsonPayload.reason="Unhealthy"

# 9. Who changed what - the audit log. Answers "why did this cluster change?"
logName="projects/PROJECT_ID/logs/cloudaudit.googleapis.com%2Factivity"
protoPayload.serviceName="container.googleapis.com"

# 10. Exclude noise so real signal is visible
resource.type="k8s_container"
severity>=WARNING
NOT jsonPayload.path="/health"
NOT jsonPayload.path="/ready"
```

### From the CLI

```bash
gcloud logging read \
  'resource.type="k8s_container" AND resource.labels.namespace_name="orders" AND jsonPayload.status>=500' \
  --limit 20 --format='table(timestamp, jsonPayload.pod, jsonPayload.path, jsonPayload.status)'

gcloud logging read 'jsonPayload.request_id="REQUEST_ID"' --format json

# Tail live
gcloud alpha logging tail 'resource.labels.namespace_name="orders"'
```

---

## Log-based metrics: turning a log line into an alert

The most useful trick in Cloud Logging. Any query can become a metric, and any
metric can become an alert.

```bash
gcloud logging metrics create orders_api_5xx \
  --description="orders-api 5xx responses" \
  --log-filter='resource.type="k8s_container"
                resource.labels.namespace_name="orders"
                jsonPayload.status>=500'
```

Then alert on its rate. This is how you catch the "green probes, failing
requests" incident that pod-health alerting cannot see.

→ [monitoring/alerts/](../monitoring/alerts/)

---

## Cost

Cloud Logging is **free to 50 GiB per project per month**, then **$0.50/GiB**.

That sounds generous and it goes quickly:

- `LOG_LEVEL=DEBUG` on a service under real load can exceed it in days.
- Access logs for `/health` and `/ready` are pure noise — this app deliberately
  **does not log probe requests** for exactly that reason.

Controls:

```bash
# What is being ingested?
gcloud logging read 'resource.type="k8s_container"' --limit 1 --format json

# Exclusion filter - stop ingesting noise entirely (cheaper than filtering later)
gcloud logging sinks create exclude-probes ... \
  --log-filter='jsonPayload.path="/health" OR jsonPayload.path="/ready"'
```

You can also disable `WORKLOADS` logging entirely
(`enable_workload_logging = false` in Terraform), which keeps system-component
logs and drops container stdout. Cheap, but you lose application logs — a poor
trade during a migration, which is exactly when you need them.

→ [COST_CONTROL.md](../COST_CONTROL.md)

---

## What good application logging looks like

The rules this app follows, and why:

| Rule | Why |
|---|---|
| **One JSON object per line** | Parseable by Cloud Logging into indexed fields |
| **Use the `severity` field name** | Cloud Logging maps it to real log levels; `level` or `lvl` won't be understood |
| **Include a request ID on every line** | Correlate one user's journey across pods and services |
| **Include version, commit, pod** | Answer "is this only happening on 2.4.17?" in one query |
| **Never log probe requests** | Pure ingestion cost, zero information |
| **Never log secrets, tokens, PII, full request bodies** | Logs are read by more people than you think, and retained for 30 days |
| **Log the exception, not just the message** | A stack trace is the difference between knowing where and guessing |
| **Log at boundaries** — start, end, dependency calls | Where things actually break |

**Never log:** passwords, tokens, API keys, full auth headers, credit-card
numbers, personal data. A log statement is a permanent, widely-readable copy.
`collect-logs.sh` scans its own bundle for credential-shaped strings before you
share it, but the real fix is not logging them in the first place.

---

## Practise it

```bash
./failure-lab/run.sh start 01     # CrashLoopBackOff
kubectl logs -n orders POD --previous          # find the cause

./failure-lab/run.sh start 15     # 30% 500s
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=200 \
  | jq -r 'select(.status>=500) | .pod' | sort | uniq -c
```

# Incident Walkthrough: Users Are Getting HTTP 500

> **"Users are reporting intermittent 500 errors. The deployment succeeded and
> everything looks healthy."**

This is the hardest kind of incident, because **every Kubernetes signal is
green**. Pods are Ready. Probes return 200. `kubectl get pods` tells you nothing
is wrong. And users are getting errors.

The skill is knowing that "healthy" at the orchestration layer and "correct" at
the application layer are different claims — and knowing how to walk the request
path to find where they diverge.

---

## First: quantify. Do not start debugging yet.

Three questions, in this order. The answers change what you do next.

```bash
./scripts/health-check.sh -n orders
```

| Question | How to answer it | Why it matters |
|---|---|---|
| **What percentage?** | 60 requests, count non-200s | 0.5% and 40% are different incidents with different urgency |
| **Since when?** | First error timestamp in logs | To correlate against deploys, config changes, dependency events |
| **Which endpoints?** | Group errors by path | One path = a code path. All paths = a dependency or infrastructure |

```bash
kubectl port-forward -n orders svc/orders-api 8080:80 &

# Real error rate
for i in $(seq 1 60); do
  curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/api/orders
done | sort | uniq -c

# When did it start?
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=1000 \
  | grep '"status":5' | head -3

# Which paths?
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=1000 \
  | grep '"status":5' | jq -r .path | sort | uniq -c | sort -rn
```

**Also ask: what changed?** Deploys, config changes, a dependency's own release,
a traffic spike, a certificate expiry, a scheduled job. Something changed. It is
almost never spontaneous.

---

## Walk the request path

A request traverses seven layers. Check them **in order**, because the answer at
each layer tells you whether to keep going.

```
   User
    │
 1  ├─► Cloud Load Balancer          ← is the LB even healthy?
    │
 2  ├─► Ingress / Gateway            ← is routing correct? backends healthy?
    │
 3  ├─► Service                      ← ARE THERE ENDPOINTS?  ← highest yield
    │
 4  ├─► Pod                          ← Ready? restarting? mixed versions?
    │
 5  ├─► Container                    ← OOM? throttled? resource starved?
    │
 6  ├─► Application logs             ← the actual exception
    │
 7  └─► Dependency                   ← DB, cache, third-party API
```

---

### Layer 1 — Load Balancer

*Skip if you're using `port-forward` or ClusterIP only.*

```bash
gcloud compute forwarding-rules list --project PROJECT
gcloud compute backend-services get-health BACKEND --global --project PROJECT
```

**Looking for:** backends `UNHEALTHY`, or a healthy count lower than your replica
count.

**If the LB is returning 502/503 rather than your app's 500:** the error is not
coming from your application at all. GCP LB error codes are distinct — a `502`
from the LB means no healthy backend, which is a very different problem from
your app returning 500.

---

### Layer 2 — Ingress

```bash
kubectl get ingress -n orders
kubectl describe ingress orders-api -n orders
```

**Looking for:** backend `UNHEALTHY`, no address assigned, TLS certificate
`FAILED_NOT_VISIBLE` or expired.

> GCE Ingress health checks are **separate** from your Kubernetes readiness
> probe. They can disagree — the LB can consider a backend unhealthy while
> Kubernetes considers the pod Ready. Check both.

---

### Layer 3 — Service and Endpoints ← **check this first if short on time**

```bash
kubectl get endpoints orders-api -n orders
```

```
NAME         ENDPOINTS                        AGE
orders-api   10.244.1.3:8080,10.244.2.4:8080  14d
```

**This one line answers an enormous amount:**

| Result | Meaning | Go to |
|---|---|---|
| `<none>` | Service routes nowhere — total outage, not intermittent | [TROUBLESHOOTING §9](../TROUBLESHOOTING.md#9-service-unreachable--no-endpoints) |
| Fewer than expected | **Partial** outage — some requests hit nothing | Layer 4 |
| Expected count | Routing is fine; keep going | Layer 4 |

**Fewer endpoints than replicas is the classic cause of *intermittent* errors.**
Two of three pods Ready means roughly one request in three fails.

---

### Layer 4 — Pods

```bash
kubectl get pods -n orders -o wide
./scripts/verify-pods.sh -n orders
```

**Looking for:**

- **`READY 0/1`** — the pod is out of rotation. If some pods are 0/1 and some
  are 1/1, that *is* your intermittency.
- **Restarts climbing** — every restart is a window where in-flight requests
  died.
- **Mixed image versions** — a stuck rollout serving two versions:

```bash
kubectl get pods -n orders -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}' | sort -u
```

More than one digest means some requests hit new code and some hit old. This
looks exactly like a flaky bug and isn't one.

- **Pods on one node** — if that node is unhealthy, so is everything on it.

---

### Layer 5 — Container resources

```bash
kubectl top pods -n orders
kubectl describe pod POD -n orders | grep -A6 "Last State"
```

**Looking for:**

- `OOMKilled` / exit 137 → the container is being killed mid-request.
  → [TROUBLESHOOTING §4](../TROUBLESHOOTING.md#4-oomkilled)
- **CPU near the limit** → throttling. Requests don't fail outright but latency
  climbs until upstream timeouts convert them into 5xx. Throttling is a
  *latency* problem that presents as an *error* problem.
- Memory near the limit → an OOM kill is imminent.

---

### Layer 6 — Application logs ← where the answer usually is

```bash
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=500 \
  | grep '"severity":"ERROR"'
```

Because this app emits structured JSON, you can slice it:

```bash
# Errors with their request IDs
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=1000 \
  | jq -c 'select(.status >= 500) | {t:.timestamp, path, request_id, pod, message}'

# Is it one pod or all of them?
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=1000 \
  | jq -r 'select(.status >= 500) | .pod' | sort | uniq -c
```

**That last query is diagnostic gold:**

```
     47 orders-api-9a1b2c-ghi      ← ONE pod failing = pod-specific problem
```
vs
```
     23 orders-api-9a1b2c-ghi
     24 orders-api-9a1b2c-jkl      ← ALL pods = code or dependency
```

One pod → restart it, check its node, check whether it's a straggler on an old
version. All pods → the version is bad or a shared dependency is failing.

**Get the full stack trace:**
```bash
kubectl logs -n orders POD --tail=500 | jq -r 'select(.exception) | .exception'
```

**And check the previous container** if anything restarted:
```bash
kubectl logs -n orders POD --previous --tail=200
```

---

### Layer 7 — Dependencies

If the application logs point outward — connection timeouts, pool exhaustion,
5xx from an upstream:

```bash
# Can the pod resolve and reach the dependency?
kubectl exec -n orders POD -- python -c \
  "import socket; print(socket.gethostbyname('DEPENDENCY_HOST'))"

# Are we hitting connection-pool limits?
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api | grep -i 'pool\|timeout\|connection'
```

**Dependency failures have a distinctive signature:** *all* pods fail *at the
same time*, and the failure rate correlates with the dependency's own metrics
rather than with your deploy.

> This is also why liveness probes must never check dependencies — otherwise
> a dependency blip restarts every replica simultaneously and turns a partial
> outage into a total one.

---

## Cloud Logging: doing this across the fleet

`kubectl logs` shows you the current pods. Cloud Logging shows you everything,
including pods that no longer exist.

```
# All 5xx from this service in the last hour
resource.type="k8s_container"
resource.labels.namespace_name="orders"
resource.labels.container_name="orders-api"
jsonPayload.status>=500

# Group by pod to see whether it is one instance or all
resource.type="k8s_container"
jsonPayload.status>=500
jsonPayload.pod="orders-api-9a1b2c-ghi"

# Follow one user's request end to end
jsonPayload.request_id="25c049a2-1819-40e3-b1ba-39fea3655f2f"

# Errors by version — did they start with 2.4.17?
resource.type="k8s_container"
jsonPayload.severity="ERROR"
jsonPayload.version="2.4.17"
```

→ [LOGGING_GUIDE.md](LOGGING_GUIDE.md)

---

## Decision point

You are now at one of four conclusions:

| Finding | Action |
|---|---|
| **Correlates with a deploy** | **Roll back.** → [ROLLBACK_RUNBOOK.md](../ROLLBACK_RUNBOOK.md) |
| **Mixed fleet** — some pods on the old version | Complete or roll back the rollout; don't leave it half-done |
| **One bad pod** | `kubectl delete pod POD` and investigate its node |
| **Dependency failure** | Escalate to that team. Consider shedding load or enabling a circuit breaker |

**If you're not sure, and the deploy is recent: roll back.** It's reversible,
it's fast, and it converts an active incident into a calm investigation. There is
no prize for root-causing in production while the error rate climbs.

---

## Practise it

```bash
./failure-lab/run.sh start 15
```

This injects a 30% error rate on `/api/orders` while `/health` and `/ready` keep
returning 200 — exactly the shape described above. Verified behaviour from a
real run of this lab:

```
--- measuring real user impact ---
RESULT -> 200s: 43   non-200: 17   (out of 60)

--- but every probe is green ---
health=200 ready=200
orders-api-9b9549787-ftlrt   1/1   Running   0   33s
orders-api-9b9549787-nqcfb   1/1   Running   0   27s
```

Two healthy pods. Two green probes. 28% of users getting errors.

Then walk the layers, roll back, and confirm:

```
after rollback:  200s: 60   non-200: 0   (out of 60)
```

---

## The lesson

**Kubernetes health checks tell you whether the platform is happy. They tell you
nothing about whether users are being served.**

A pod that returns 200 on `/health` and 500 on every real request is, as far as
Kubernetes is concerned, perfectly healthy. It will stay in the Service, keep
receiving traffic, and never restart.

That gap is exactly why:

- **Alert on the 5xx rate**, not on pod health. This is the alert that catches
  this class of incident, and nothing else does.
- **Smoke-test business endpoints**, not just probes — and with enough requests
  to detect a partial failure rate. One request against a 30% failure rate
  passes 70% of the time.
- **Emit structured logs** with request IDs, pod names and versions, so you can
  slice by pod and by version in one query.

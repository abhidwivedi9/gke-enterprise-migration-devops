# Dashboard Guide

What each panel means, what "normal" looks like, and what to do when it moves.

**Read the panels in the order below.** It goes from "is the platform sound?" to
"are users being served?" — and the second question is the one that matters. A
dashboard where every infrastructure panel is green and the error-rate panel is
red is not a contradiction; it is the most common shape of a real incident.

---

## How to use this during an incident

Three passes, 30 seconds each:

1. **Is anything obviously broken?** — nodes, replicas, endpoints.
2. **Are users affected?** — error rate, latency. *This is the one that decides
   urgency.*
3. **Did something change?** — version panel, deployment events, restarts.

Then go to [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) with a hypothesis, rather
than opening it cold.

---

## CLUSTER HEALTH

### Nodes Ready
**Normal:** equals your node count, flat line.
**What it means:** how much capacity actually exists.
**When it drops:** every pod on that node is unreachable or rescheduling. On
**Spot VMs** (this project's default) the most likely cause is preemption —
Google reclaimed the node with 30 seconds' notice. That's the trade for the
60–91% discount, and it's why `minReplicas: 2` and topology spread exist.

```bash
kubectl get nodes
kubectl describe node NODE | grep -A10 Conditions
```

### Node CPU / memory utilisation
**Normal:** under 70%. **Investigate:** above 80%. **Act:** above 90%.
**What it means:** how close the cluster is to being unable to schedule anything
new.
**Why it matters more than it looks:** at high utilisation, the HPA can decide to
scale and the scheduler has nowhere to put the pods. Autoscaling silently stops
working, and the only symptom is `Pending` pods.

### Nodes NOT Ready
**Normal: 0.** Anything above 0 is an incident. Watch for `MemoryPressure` and
`DiskPressure` — both predict outages before they happen. DiskPressure in
particular starts failing *image pulls*, which looks like a registry problem.

---

## APPLICATION HEALTH

### Replicas: desired vs available
**Normal:** the two lines overlap exactly.
**What it means:** whether you have the capacity you think you have.

| Shape | Meaning |
|---|---|
| Lines overlap | Healthy |
| `available` briefly dips during a deploy | Normal rolling update |
| `available` below `desired` for minutes | **Degraded** — one more failure could take you down |
| `available` at 0 | **Full outage** |

A gap that nobody notices is the dangerous case: you're running on reduced
capacity with no alarm, until a second pod fails.

### Container restarts
**Normal: flat at 0.**
**Alert on the RATE, not the total** — a cumulative count alerts forever after
one historical restart, then gets muted, and then you have no alert at all.

The restart *reason* is what identifies the problem. `RESTARTS: 7` tells you
nothing; `OOMKilled, exit 137` tells you everything.

```bash
kubectl describe pod POD -n orders | grep -A6 "Last State"
kubectl logs POD -n orders --previous
```

| Exit code | Meaning | Runbook |
|---|---|---|
| 137 | SIGKILL — OOMKilled or grace period expired | [§4](../TROUBLESHOOTING.md#4-oomkilled) |
| 143 | SIGTERM — liveness failure, eviction, rollout | [§6](../TROUBLESHOOTING.md#6-liveness-probe-failure) |
| other | The app (or its supervisor) chose to exit | [§3](../TROUBLESHOOTING.md#3-crashloopbackoff) |

> A supervisor or ASGI server can rewrite the application's exit code — this
> app's `sys.exit(1)` surfaces as exit 3. Only 137 and 143, which originate
> outside the process, are fully reliable.

### Pods by phase
Watch for `Pending` (scheduler can't place it — capacity, taints, or affinity)
and `CrashLoopBackOff`. During a deploy, a brief overlap of old and new pods is
expected; a *sustained* overlap means the rollout is stuck.

---

## APPLICATION PERFORMANCE — the panels that matter most

> Requires Managed Prometheus. **If you enable only one group of panels, make it
> this one.** Everything above tells you whether Kubernetes is happy. Only these
> tell you whether users are being served.

### Request rate by status
**Normal:** follows your daily traffic curve; almost entirely 2xx.

| Shape | Meaning |
|---|---|
| Sudden drop to zero | Traffic isn't arriving — LB, DNS, or Ingress, not your app |
| 4xx climbing | Client-side: bad requests, auth failures, a broken caller |
| 5xx climbing | **Your problem.** Go to the next panel |
| Rate doubles without a deploy | Traffic spike, retry storm, or a caller in a loop |

A **retry storm** is worth recognising: an upstream retrying failed requests
multiplies your load exactly when you're least able to handle it.

### 5xx error rate — the single most important panel

**Normal: below 0.1%.** Alert at 1%. Page at 5%.

**This is the panel that catches the incident nothing else can see.** A pod that
returns 200 on `/health` and 500 on every real request is, as far as Kubernetes
is concerned, perfectly healthy. It stays in the Service, keeps receiving
traffic, and never restarts.

When this climbs:

1. **Quantify** — what %, since when, which endpoints
2. **Correlate** — `helm history orders-api -n orders`. Did a deploy just happen?
3. **Localise** — one pod or all pods?
   ```bash
   kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=1000 \
     | jq -r 'select(.status>=500) | .pod' | sort | uniq -c
   ```
   One pod → restart it, check its node. All pods → bad version or a dependency.
4. **Roll back if it correlates with a deploy.** Don't root-cause first.

→ [docs/INCIDENT_HTTP_500.md](../docs/INCIDENT_HTTP_500.md)

### Latency p50 / p95 / p99

**Why three percentiles and never an average:** if 90% of requests take 10 ms and
10% take 5 s, the average looks acceptable and one user in ten is having an
awful time. The average is the least useful latency statistic there is.

| Reading | Meaning |
|---|---|
| p50 flat, p99 spiking | A subset of requests is pathological — a slow query, a cold cache, one bad pod |
| All three rise together | Systemic — CPU throttling, a slow dependency, or saturation |
| Step change at a deploy | The new version is slower. **A version that's 3× slower is a failed deploy even if it returns 200.** |

Rising latency is often the *early warning* for a 5xx incident: requests get
slower until upstream timeouts convert slowness into errors.

---

## DEPLOYMENT & VERSION

### Running versions — should be exactly one

**Normal: one line.**

**More than one line = a mixed fleet**, and it is the explanation for a large
share of "intermittent" bugs. Some requests hit the new code, some hit the old.
A bug appears to be fixed two times out of three. Averaged metrics hide it
completely, and a single `curl` gives you a false green.

During a rolling update, two versions briefly is normal. Two versions *five
minutes later* means the rollout is stuck.

```bash
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17
```

→ [docs/VERSION_VERIFICATION.md](../docs/VERSION_VERIFICATION.md)

### Pods ready (`app_ready`)
The application's own opinion about whether it can serve, independent of what
Kubernetes thinks. When this and the replica panel disagree, trust this one.

---

## AUTOSCALING & RESOURCES

### CPU: usage vs request
**Normal:** below the HPA target (70%).

**The key fact:** the HPA scales on utilisation *of the request*, not of the limit
and not of the node. With `requests.cpu: 50m` and a 70% target, the HPA aims to
keep each pod near 35m.

If this sits above target and replicas aren't climbing, the HPA is not working:

```bash
kubectl get hpa -n orders          # <unknown>/70% = it is blind
kubectl top pods -n orders         # works? -> requests.cpu unset. fails? -> metrics-server
```

**Also remember CPU is compressible.** Exceeding the CPU *limit* throttles rather
than kills, so the user-visible symptom is latency, not errors — until upstream
timeouts turn it into 5xx. A latency incident with flat error rates and CPU
pinned at the limit is almost always throttling.

→ [docs/AUTOSCALING.md](../docs/AUTOSCALING.md)

### Memory: usage vs limit — the OOM predictor

**Normal:** below 70%. **Alert at 85%.**

**Memory is incompressible.** Unlike CPU, exceeding the limit means the kernel
kills the container instantly with no chance to log anything. Alerting on an
OOMKill that already happened tells you about an outage you failed to prevent;
85% gives you time to act.

The *shape* of this graph is the diagnosis:

| Shape | Meaning | Fix |
|---|---|---|
| Sawtooth that plateaus | Normal GC behaviour | Nothing |
| Rises then flattens near the limit | **Limit too low** | Raise `resources.limits.memory` |
| Climbs monotonically, never returns | **Memory leak** | Raising the limit only delays the crash — fix the leak |

---

## OPERATIONAL — recent errors

The live error stream. Use `request_id` to follow a single user's request end to
end; if you propagate it across services it becomes a poor-man's distributed
trace.

```
jsonPayload.request_id="25c049a2-1819-40e3-b1ba-39fea3655f2f"
```

→ [docs/LOGGING_GUIDE.md](../docs/LOGGING_GUIDE.md)

---

## Reading it during a deploy

Watch these five, in this order, for 10–15 minutes after every release:

1. **Replicas** — `available` returns to `desired`, briefly dipping at most
2. **Restarts** — stays flat. Any restart during a deploy deserves a look
3. **Versions** — collapses back to exactly one line
4. **Error rate** — returns to baseline. **Compare against the pre-deploy
   baseline, not against zero**
5. **Latency** — p95 within ~20% of the previous version

**Watch for the full 10–15 minutes.** Memory leaks, connection-pool exhaustion
and cache-related failures only appear after the new version has served real
traffic for a while. A deploy that looks perfect after 60 seconds can still be
failing at minute 12.

---

## No GCP? Same panels, zero cost

```bash
./monitoring/ops-dashboard.sh -n orders --watch
```

Real output from this project's kind cluster:

```
── APPLICATION HEALTH ──────────────────────────────────────
   ● replicas: 2/2 available
   ● restarts: 0

── TRAFFIC ROUTING ─────────────────────────────────────────
   ● endpoints: 2 pod(s) behind the Service

── AUTOSCALING ─────────────────────────────────────────────
     min 2    max 4    current 2     cpu 12%/70%
   ● HPA is reading metrics

── REQUEST SUCCESS RATE  (live sample) ─────────────────────
   ● 20/20 requests succeeded (100%)
     /version reports: 2.4.17
```

During an incident this is often *faster* than a browser dashboard: one command,
and it shows the specific fields that matter rather than graphs you have to
interpret.

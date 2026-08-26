# Troubleshooting Runbook

Open this during an incident. Find your symptom, run the commands, follow the
path.

**Practise these:** every failure below can be injected on demand with
[`./failure-lab/run.sh`](failure-lab/README.md). Reading a runbook is not the
same as having used it under pressure.

---

## Start here — the 60-second triage

```bash
./scripts/health-check.sh -n orders     # the whole sweep in one command
./scripts/verify-pods.sh -n orders      # classify every unhealthy pod
```

Or by hand, in this order:

```bash
kubectl get pods -n orders -o wide                              # 1. what state?
kubectl get events -n orders --sort-by=.lastTimestamp | tail -20 # 2. what changed?
kubectl get endpoints orders-api -n orders                       # 3. is traffic routed?
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=50
```

**Before you start fixing, preserve evidence** — fixing destroys it:

```bash
./scripts/collect-logs.sh -n orders
```

Events are garbage-collected after ~1 hour. `--previous` logs hold only the
*last* terminated container — a second restart overwrites them. Deleting a
Deployment destroys its pods and their logs with it.

---

## Read the STATUS column

| STATUS / READY | Meaning | Go to |
|---|---|---|
| `Pending` | Scheduler cannot place it | [§1](#1-pending) |
| `ContainerCreating` (stuck) | Image pull or volume mount | [§2](#2-imagepullbackoff--errimagepull), [§10](#10-volume-mount-failures) |
| `ImagePullBackOff` / `ErrImagePull` | Cannot fetch the image | [§2](#2-imagepullbackoff--errimagepull) |
| `CrashLoopBackOff` | Starts, exits, repeats | [§3](#3-crashloopbackoff) |
| `Running` + `0/1` | Readiness failing — **no traffic** | [§5](#5-readiness-probe-failure) |
| `Running` + restarts climbing | Liveness or OOM | [§4](#4-oomkilled), [§6](#6-liveness-probe-failure) |
| `CreateContainerConfigError` | Missing ConfigMap/Secret **key** | [§8](#8-missing-configmap-or-secret) |
| `Terminating` (stuck) | Finalizer or long grace period | [§11](#11-pod-stuck-terminating) |
| `Evicted` | Node resource pressure | [§12](#12-node-notready--pod-evicted) |
| `Completed` | Process exited 0 — wrong for a service | [§3](#3-crashloopbackoff) |

---

## 1. Pending

**SYMPTOM** — Pod never starts. No container exists, therefore **no logs exist**.
Reaching for `kubectl logs` here is the classic wasted first move.

**COMMAND**
```bash
kubectl describe pod POD -n orders | tail -20
kubectl describe nodes | grep -A8 "Allocated resources"
kubectl get nodes
```

**OUTPUT TO LOOK FOR**
```
Warning  FailedScheduling  0/3 nodes are available:
  3 Insufficient cpu.
```

**ROOT CAUSE** — decide which by reading the message verbatim:

| Message | Cause | Fix |
|---|---|---|
| `Insufficient cpu` / `memory` | Not enough **requested** capacity free | Lower requests, or add nodes |
| `node(s) had untolerated taint` | Taint/toleration mismatch | Add a toleration, or remove the taint |
| `node(s) didn't match Pod's node affinity` | nodeSelector/affinity matches nothing | Fix the selector, or label the node |
| `pod has unbound immediate PersistentVolumeClaims` | No PV available | Check StorageClass and PVC |
| `didn't match pod topology spread constraints` | `DoNotSchedule` can't be satisfied | Use `ScheduleAnyway`, or add nodes |

> **The trap:** scheduling is based on **requests**, not usage. A cluster idling
> at 5% actual CPU can be 100% *requested* and completely unschedulable.

**FIX**
```bash
kubectl top nodes                                          # real usage
helm upgrade ... --set resources.requests.cpu=50m          # right-size
gcloud container clusters resize NAME --num-nodes=2 --zone ZONE   # COSTS MONEY
```

**VALIDATION** — `kubectl get pod POD -n orders -o wide` shows a node name.

**PREVENTION** — set requests from observed usage; cluster autoscaler with a
`max_node_count` ceiling; alert on Pending > 5 min.

---

## 2. ImagePullBackOff / ErrImagePull

**SYMPTOM** — Pod never starts, zero restarts (no container ever ran).

**COMMAND**
```bash
kubectl describe pod POD -n orders | tail -15
gcloud artifacts docker images list REGION-docker.pkg.dev/PROJECT/orders
```

**OUTPUT TO LOOK FOR**
```
Failed to pull image "...:2.4.17": not found
# or
denied: Permission "artifactregistry.repositories.downloadArtifacts" denied
```

**ROOT CAUSE** — check in this order:

1. **Tag doesn't exist** — typo, or CI never pushed.
   ```bash
   gcloud artifacts docker images describe REGION-docker.pkg.dev/PROJECT/orders/orders-api:2.4.17
   ```
   Either it resolves to a digest or it doesn't. That settles the "but I pushed
   it" argument in ten seconds.
2. **Permission** — node SA lacks `roles/artifactregistry.reader`.
3. **Wrong registry path** — pushed to one project/region, pulling from another.
4. **Network** — private nodes with neither Cloud NAT nor Private Google Access.
5. **On kind** — you forgot `kind load docker-image`.

**FIX**
```bash
gcloud artifacts repositories add-iam-policy-binding orders \
  --location=REGION --member="serviceAccount:NODE_SA" \
  --role="roles/artifactregistry.reader"
kubectl set image deployment/orders-api orders-api=CORRECT_IMAGE -n orders
```

**VALIDATION** — `kubectl describe pod` shows a `Pulled` event.

**PREVENTION** — verify the push by pulling it back in CI; deploy by digest;
immutable tags.

---

## 3. CrashLoopBackOff

**SYMPTOM** — Restarts climb. Status cycles `Error` → `CrashLoopBackOff`.
Backoff grows 10s → 20s → 40s → … capped at 5 min, so a fix takes up to five
minutes to visibly take effect. Don't conclude your fix failed too early.

**COMMAND**
```bash
kubectl logs POD -n orders --previous      # ← THE command
kubectl describe pod POD -n orders | grep -A6 "Last State"
```

> **`--previous` is the whole game.** The *current* container just started and
> hasn't failed yet. The reason it died is in the *previous* one.

**OUTPUT TO LOOK FOR**
```
Last State: Terminated
  Reason: Error
  Exit Code: 3
```

**Exit codes — but read the caveat:**

| Code | Meaning |
|---|---|
| 0 | Clean exit. For a long-running service, still a bug. |
| 1, 2, 3… | The application (or its supervisor) chose to exit |
| 137 | **SIGKILL** — OOMKilled, or grace period expired → [§4](#4-oomkilled) |
| 143 | **SIGTERM** — Kubernetes asked it to stop (liveness, eviction, rollout) |

> **Caveat:** this app calls `sys.exit(1)`, but the container reports **exit 3**,
> because uvicorn catches `SystemExit` and exits with its own code. Any
> supervisor, wrapper script, or ASGI server between your code and PID 1 can
> rewrite the exit code. Codes that originate *outside* the process — 137, 143 —
> are the reliable ones.

**ROOT CAUSE** — bad/missing config, unreachable dependency at boot, failed
migration, wrong entrypoint, import error.

**FIX** — read the previous logs, fix what they name. Do **not** raise the
restart limit; that hides the symptom.

**VALIDATION** — `kubectl get pods` shows `Running 1/1` with a stable restart
count.

**PREVENTION** — fail fast with a *specific* message naming the missing thing;
validate config in CI; `helm upgrade --atomic`.

---

## 4. OOMKilled

**SYMPTOM** — Periodic restarts. Logs look normal right up to the moment of
death, because the kernel gives the process no chance to log anything.

**COMMAND**
```bash
kubectl describe pod POD -n orders | grep -A6 "Last State"
kubectl get pod POD -n orders -o jsonpath='{.spec.containers[0].resources}'
kubectl top pods -n orders
```

**OUTPUT TO LOOK FOR** — `Reason: OOMKilled`, `Exit Code: 137`.

**ROOT CAUSE** — two very different situations, and you must distinguish them:

- **Limit too low** — the app legitimately needs more. Memory over time is a
  sawtooth that plateaus. Raise the limit.
- **Memory leak** — usage climbs monotonically and never returns. Raising the
  limit only delays the crash.

> Also possible: **node-level** memory pressure rather than the container limit.
> Check `kubectl describe node | grep MemoryPressure`.

**FIX**
```bash
helm upgrade ... --set resources.limits.memory=256Mi
```

**VALIDATION** — `kubectl top pods` stabilises below the new limit; restarts stop.

**PREVENTION** — limit = observed peak + headroom; `requests.memory ==
limits.memory` for Guaranteed QoS; **alert at 85% of limit**, which fires
*before* the kill.

---

## 5. Readiness probe failure

**SYMPTOM** — `Running`, `READY 0/1`, zero restarts, and the service is
unreachable.

**COMMAND**
```bash
kubectl get endpoints orders-api -n orders     # expect <none>
kubectl describe pod POD -n orders | grep -A5 Readiness
kubectl logs POD -n orders --tail=50
```

**ROOT CAUSE** — the app reports not-ready, so the endpoints controller removed
it from the Service. **This is Kubernetes working correctly.** The question is
why the app says it can't serve: a dependency is down, a cache hasn't warmed, or
the probe path/port/scheme is simply wrong.

> If **every** replica goes 0/1 at the same moment, suspect the shared
> dependency, not the pods.

**FIX** — fix the dependency, or correct the probe definition.

**VALIDATION** — `kubectl get endpoints` lists the pod IP.

**PREVENTION** — readiness reflects real serving capability; alert on
`kube_endpoint_address_available == 0`.

---

## 6. Liveness probe failure

**SYMPTOM** — Restarts climb on a service that behaves perfectly whenever you
catch it running. Often clusters around traffic peaks.

**COMMAND**
```bash
kubectl describe pod POD -n orders | grep -B2 -A8 Liveness
kubectl get events -n orders | grep -i unhealthy
```

**OUTPUT TO LOOK FOR** — `Liveness probe failed`, `will be restarted`,
`Exit Code: 143`.

**ROOT CAUSE** — the probe is too aggressive for a process that is genuinely
alive:
- it checks a **dependency** (so a database blip restarts every replica at once,
  turning a partial outage into a total one);
- `timeoutSeconds` shorter than a normal GC pause;
- `failureThreshold: 1` on a service with occasional latency spikes.

**FIX**
```bash
helm upgrade ... \
  --set probes.liveness.failureThreshold=3 \
  --set probes.liveness.timeoutSeconds=3
```

**VALIDATION** — restart count holds steady under load.

**PREVENTION** — **liveness answers one question: is the process wedged?**
Dependency checks belong in readiness. Alert on restart *rate*, not count.

---

## 7. Startup probe failure

**SYMPTOM** — Pods never become Ready, restart forever, but only on first start.

**COMMAND** — `kubectl describe pod POD -n orders | grep -A5 Startup`

**ROOT CAUSE** — `failureThreshold × periodSeconds` < real boot time. The
container is killed mid-boot and never gets far enough to pass.

**FIX** — widen the budget past the *worst observed* boot time:
```bash
helm upgrade ... --set probes.startup.failureThreshold=60   # 60 × 2s = 120s
```

**PREVENTION** — prefer a startup probe over a large `initialDelaySeconds`: a
startup probe lets a *fast* boot become Ready immediately, whereas
`initialDelaySeconds: 120` makes every pod wait the full two minutes.

---

## 8. Missing ConfigMap or Secret

**SYMPTOM** — `CreateContainerConfigError`, or the app exits immediately with a
config error.

**COMMAND**
```bash
kubectl describe pod POD -n orders | tail -15
kubectl get cm,secrets -n orders
kubectl logs POD -n orders --previous
```

**OUTPUT TO LOOK FOR** — `secret "orders-api-secrets" not found`, or
`couldn't find key ORDERS_DB_DSN`.

**ROOT CAUSE** — typo, missing bootstrap step in a fresh namespace, or the
Secret is in a different namespace. **Secrets are namespaced and cannot be
referenced across namespaces.**

**FIX**
```bash
kubectl create secret generic orders-api-secrets -n orders \
  --from-literal=ORDERS_DB_DSN='...'
kubectl rollout restart deployment/orders-api -n orders
```

**PREVENTION** — Secret Manager + CSI; validate required keys in CI.

---

## 9. Service unreachable / no endpoints

**SYMPTOM** — Pods perfectly healthy; the Service returns nothing.

**COMMAND**
```bash
kubectl get endpoints orders-api -n orders          # THE diagnostic
kubectl get svc orders-api -n orders -o jsonpath='{.spec.selector}'
kubectl get pods -n orders --show-labels
```

**ROOT CAUSE** — empty endpoints means exactly one of two things:
1. **Selector matches nothing** — compare `spec.selector` against pod labels.
2. **No matching pod is Ready** — only Ready pods appear in Endpoints → [§5](#5-readiness-probe-failure).

If endpoints *exist* but connections still fail, suspect a **`targetPort`
mismatch** — the Service points at a port nothing is listening on.

**FIX** — correct the selector, or fix readiness.

**VALIDATION**
```bash
kubectl port-forward -n orders svc/orders-api 8080:80
curl localhost:8080/health
```

**PREVENTION** — generate selector and pod labels from one Helm helper; alert on
`kube_endpoint_address_available == 0`.

---

## 10. Volume mount failures

**SYMPTOM** — Stuck in `ContainerCreating`.

**COMMAND**
```bash
kubectl describe pod POD -n orders | grep -A10 Volumes
kubectl get pvc -n orders
```

**ROOT CAUSE** — unbound PVC, wrong StorageClass, a zonal disk in a different
zone from the node, or a ReadWriteOnce volume already attached elsewhere.

**FIX** — match the StorageClass; for RWO, ensure only one pod attaches;
`Recreate` strategy rather than `RollingUpdate` for RWO workloads.

---

## 11. Pod stuck Terminating

**SYMPTOM** — Pod sits in `Terminating` well past its grace period.

**COMMAND**
```bash
kubectl get pod POD -n orders -o jsonpath='{.metadata.finalizers}'
kubectl describe pod POD -n orders
```

**ROOT CAUSE** — a finalizer waiting on something that will never happen; the
process ignoring SIGTERM; a stuck volume detach; or a node that is gone entirely.

**FIX**
```bash
# Investigate FIRST. Force-delete removes the API object while the container may
# still be running on the node - for a StatefulSet that risks split-brain.
kubectl delete pod POD -n orders --grace-period=0 --force
```

**PREVENTION** — handle SIGTERM properly (this app flips readiness off, then
drains); keep `terminationGracePeriodSeconds` > preStop + drain + longest
request.

---

## 12. Node NotReady / pod Evicted

**SYMPTOM** — Pods on one node go `Unknown`, get evicted, or the node shows
`NotReady`.

**COMMAND**
```bash
kubectl get nodes
kubectl describe node NODE | grep -A10 Conditions
kubectl top nodes
```

**OUTPUT TO LOOK FOR** — `MemoryPressure: True`, `DiskPressure: True`, or
`Ready: Unknown` (kubelet stopped reporting).

**ROOT CAUSE** — node resource exhaustion, kubelet crash, network partition, or
— on Spot VMs — **preemption**. Spot nodes can be reclaimed with 30 seconds'
notice; that is the trade you accepted for the 60–91% discount.

**FIX**
```bash
kubectl cordon NODE
kubectl drain NODE --ignore-daemonsets --delete-emptydir-data
# GKE node auto-repair handles most of this automatically
```

**PREVENTION** — node auto-repair (enabled in this Terraform); PDB + topology
spread so one node isn't a single point of failure; alert on node conditions.

---

## 13. HPA not scaling

→ Full guide: **[docs/AUTOSCALING.md](docs/AUTOSCALING.md)**

**COMMAND**
```bash
kubectl get hpa -n orders
kubectl describe hpa orders-api -n orders
kubectl top pods -n orders
```

**`TARGETS: <unknown>/70%`** — one of two causes, and `kubectl top` tells you
which in one command:
- `top` **fails** → metrics-server isn't running.
- `top` **works** → `resources.requests.cpu` is unset. Utilisation is a
  percentage *of the request*; with no request there's no denominator.

**Valid metrics but still no scaling:** already at `maxReplicas`; new pods stuck
`Pending`; scale-down stabilisation window still open; or CPU isn't actually the
bottleneck (it's I/O).

---

## 14. Node drain hangs

**SYMPTOM** — `kubectl drain` never completes; cluster upgrades stall.

**COMMAND** — `kubectl get pdb -n orders`

**OUTPUT TO LOOK FOR** — `ALLOWED DISRUPTIONS: 0`.

**ROOT CAUSE** — `minAvailable` equals replica count, so no pod may ever be
voluntarily evicted. A PDB governs **voluntary** disruptions only — it does
nothing about a node hard-failing.

**FIX** — `--set podDisruptionBudget.minAvailable=1`, or raise replicas.

**PREVENTION** — keep `minAvailable` strictly below `replicaCount`, or express
it as a percentage. Test a drain during migration validation, not at 02:00
during an upgrade.

---

## 15. Wrong version running

→ Full guide: **[docs/VERSION_VERIFICATION.md](docs/VERSION_VERIFICATION.md)**

```bash
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17 \
  --registry REGION-docker.pkg.dev/PROJECT/orders
```

Every layer can report success while the wrong code runs. The only ground truth
is the running process's own `/version`.

---

## 16. Users get HTTP 500 but everything looks healthy

→ Full walkthrough: **[docs/INCIDENT_HTTP_500.md](docs/INCIDENT_HTTP_500.md)**

This is the most important scenario in the runbook, because **every Kubernetes
signal is green**. Probes return 200. Pods are Ready. `kubectl` tells you
nothing is wrong.

```bash
./scripts/health-check.sh -n orders     # step 7 measures the REAL success rate
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api | grep '"status":5'
curl -s localhost:8080/metrics | grep 'status="500"'
```

**Roll back first, root-cause second.** Stopping user impact takes priority over
understanding the bug.

---

## Diagnostic decision tree

```
Users report a problem
   │
   ├─ Is anything actually broken?  ./scripts/health-check.sh -n orders
   │
   ├─ Pods not Running? ────────────► §1 §2 §3 §4
   │
   ├─ Running but 0/1 Ready? ───────► §5
   │
   ├─ Restarts climbing? ───────────► exit 137 → §4 · exit 143 → §6 · other → §3
   │
   ├─ Pods healthy, service dead? ──► §9  (check endpoints FIRST)
   │
   ├─ Pods healthy, users see 5xx? ─► §16 (the dangerous one)
   │
   ├─ Wrong behaviour after deploy? ► §15
   │
   └─ Slow / not scaling? ──────────► §13
```

## Escalate when

- Users are affected and you don't have a hypothesis within 15 minutes
- The fix requires a change you can't reverse
- Data loss or corruption is possible
- It spans teams (database, network, a third party)

**Roll back first.** You can debug a bad release at leisure once it's out of
production. → [ROLLBACK_RUNBOOK.md](ROLLBACK_RUNBOOK.md)

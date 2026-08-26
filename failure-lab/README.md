# Failure Lab

Fifteen controlled failures. Every one reproduces something that actually
happens in production, and every one is diagnosable with nothing but `kubectl`.

```bash
./failure-lab/run.sh list
./failure-lab/run.sh start 01
# ... diagnose it yourself ...
./failure-lab/run.sh explain 01
./failure-lab/run.sh reset
```

**Use it properly:** inject the failure, then spend real time not knowing. The
learning is in the minutes between "something is wrong" and "I know what it is."
Reading the answer first converts an exercise into a blog post.

Each scenario below follows the same structure:

> SYMPTOM → COMMAND → OUTPUT TO LOOK FOR → ROOT CAUSE → FIX → VALIDATION →
> PREVENTION → INTERVIEW QUESTION

---

## 01 CrashLoopBackOff — container exits non-zero on boot

**SYMPTOM**
Pods never reach Ready. `RESTARTS` climbs steadily. Status cycles between
`Error`, `CrashLoopBackOff`, and briefly `Running`. The restart interval grows:
10s, 20s, 40s, 80s… capped at 5 minutes.

**COMMAND**
```bash
kubectl get pods -n orders
kubectl describe pod <POD> -n orders | tail -20
kubectl logs <POD> -n orders --previous
```

**OUTPUT TO LOOK FOR**
```
STATUS: CrashLoopBackOff   RESTARTS: 2 (11s ago)
Last State: Terminated
  Reason: Error
  Exit Code: 3
Back-off restarting failed container
```

**A detail worth pausing on:** the application calls `sys.exit(1)`, but the
container reports **exit code 3**. Uvicorn catches `SystemExit` during startup,
logs `Application startup failed. Exiting.`, and exits with its *own* code. So
the exit code tells you the container died — it does **not** reliably tell you
which code the application chose. Never diagnose from the exit code alone when
a supervisor, wrapper script or ASGI server sits between your code and PID 1.
(The codes that *are* reliable come from outside the process: 137 = SIGKILL/OOM,
143 = SIGTERM.)

**Also notice what did NOT happen:** the two old pods are still `Running` and
still serving. `maxUnavailable: 0` means the rollout refuses to remove healthy
old pods until new ones are Ready. The deploy is stuck, not down — which is
exactly the behaviour you want, and the reason `kubectl rollout status` is the
check that catches this rather than a user complaint.

**The single most important detail:** `--previous`. The *current* container has
only just started and has not failed yet, so `kubectl logs <POD>` shows almost
nothing. The reason it died is in the *previous* container's logs. Engineers
lose hours to this.

**ROOT CAUSE**
The process exits non-zero during startup. In the real world this is almost
always one of: missing/invalid configuration, a dependency unreachable at boot,
a failed database migration, a bad command/entrypoint, or a code-level import
error. Here, `CRASH_ON_START=true` makes the app `sys.exit(1)` deliberately.

**FIX**
```bash
kubectl logs <POD> -n orders --previous   # read the actual error first
helm upgrade orders-api ./helm/application ... --set faultInjection.crashOnStart=false
```
Fix the cause the logs name. Do not raise the restart limit — that hides the
symptom and changes nothing.

**VALIDATION**
```bash
kubectl get pods -n orders          # Running, 1/1, RESTARTS stops climbing
kubectl rollout status deployment/orders-api -n orders
```

**PREVENTION**
- Fail fast **with a specific message**: name the exact missing variable, as
  this app does for `ORDERS_DB_DSN`.
- Validate config in CI, before the image ships.
- `--atomic` on `helm upgrade`, so a crash-looping release rolls itself back.
- Alert on `kube_pod_container_status_restarts_total` increasing, not just on
  pods being down.

**INTERVIEW QUESTION**
*"A pod is in CrashLoopBackOff. Walk me through your first five commands."*
A strong answer names `--previous` unprompted, checks `describe` for exit code
and reason before opening logs, distinguishes exit 1 (application error) from
137 (OOMKilled) and 143 (SIGTERM), and mentions that the backoff timer means a
fix takes up to 5 minutes to visibly take effect.

---

## 02 ImagePullBackOff — the tag does not exist

**SYMPTOM**
Pods stay `Pending`/`ContainerCreating`, then flip to `ErrImagePull` and settle
into `ImagePullBackOff`. Zero restarts, because no container ever started.

**COMMAND**
```bash
kubectl describe pod <POD> -n orders | tail -15
kubectl get events -n orders --sort-by=.lastTimestamp | tail
```

**OUTPUT TO LOOK FOR**
```
Failed to pull image "orders-api:9.9.9-does-not-exist":
  failed to resolve reference: not found
Warning  Failed   ErrImagePull
Warning  Failed   ImagePullBackOff
```

**ROOT CAUSE**
The kubelet cannot obtain the image. Exactly four causes, in the order worth
checking:
1. **The tag does not exist** — typo, or CI never actually pushed.
2. **Authentication** — the node service account lacks
   `roles/artifactregistry.reader`.
3. **Wrong registry path** — pushed to `us-central1-docker.pkg.dev`, pulling
   from `gcr.io`, or a different project.
4. **Networking** — private nodes with no Cloud NAT *and* no Private Google
   Access, so the registry is simply unreachable.

On kind, there is a fifth: you forgot `kind load docker-image`.

**FIX**
```bash
# 1. does the tag exist?
gcloud artifacts docker images list REGION-docker.pkg.dev/PROJECT/orders

# 2. can the node SA read it?
gcloud artifacts repositories get-iam-policy orders --location=REGION

# 3. correct the image reference
kubectl set image deployment/orders-api orders-api=<CORRECT_IMAGE> -n orders
```

**VALIDATION**
```bash
kubectl get pods -n orders -w
kubectl describe pod <POD> -n orders | grep -A3 "Events"   # expect: Pulled
```

**PREVENTION**
- Verify the push in CI *by pulling it back* before deploying.
- Deploy by **digest**, not tag.
- Immutable tags in Artifact Registry (this repo's Terraform sets that).
- A smoke job that pulls the exact image the Deployment references.

**INTERVIEW QUESTION**
*"ImagePullBackOff in production. The developer swears the image was pushed.
How do you settle it?"*
Strong answer: `gcloud artifacts docker images describe` the exact tag — either
it resolves to a digest or it does not; that ends the argument in ten seconds.
Then check the node SA's IAM, then compare the registry host in the Deployment
against the one CI pushed to.

---

## 03 Pending pod — no node has enough CPU

**SYMPTOM**
Pod sits in `Pending` indefinitely. No container, therefore **no logs at all** —
`kubectl logs` returns nothing useful, which throws people who reach for logs
first.

**COMMAND**
```bash
kubectl get pods -n orders
kubectl describe pod <POD> -n orders | tail -10
kubectl describe nodes | grep -A6 "Allocated resources"
```

**OUTPUT TO LOOK FOR**
```
Events:
  Warning  FailedScheduling  0/3 nodes are available:
    3 Insufficient cpu. preemption: 0/3 nodes are available:
    3 No preemption victims found for incoming pod.
```

**ROOT CAUSE**
The **scheduler**, not the kubelet, is stuck. No node has enough *allocatable*
CPU left to satisfy `resources.requests.cpu`. Note it is requests, not actual
usage: a cluster idling at 5% real CPU can still be 100% *requested*.

Other producers of `Pending`: nodeSelector/affinity matching nothing, an
un-tolerated taint, an unbound PVC, or topology spread with `DoNotSchedule`.

**FIX**
```bash
# Right-size the request to what the app actually uses
kubectl top pods -n orders
helm upgrade ... --set resources.requests.cpu=50m
# or add capacity
gcloud container clusters resize CLUSTER --num-nodes=2 --zone ZONE   # COSTS MONEY
```

**VALIDATION**
```bash
kubectl get pod <POD> -n orders -o wide    # a node name appears
kubectl describe nodes | grep -A6 "Allocated resources"
```

**PREVENTION**
- Set requests from observed usage (`kubectl top`), not from guesses.
- Cluster autoscaler with a **max node count**, which bounds both capacity and
  cost.
- Alert on `kube_pod_status_phase{phase="Pending"} > 0` for more than 5 minutes.
- ResourceQuota per namespace, so one team cannot consume the cluster.

**INTERVIEW QUESTION**
*"A pod is Pending. `kubectl logs` shows nothing. Why, and what do you do?"*
Strong answer: there are no logs because no container exists — scheduling
happens before the kubelet is involved. Go to `describe pod` events. Then
distinguish resource pressure from affinity/taint/PVC causes, and note that the
scheduler works on *requests*, so a visually idle cluster can still be full.

---

## 04 OOMKilled — memory limit below actual usage

**SYMPTOM**
Container restarts periodically. `RESTARTS` climbs. The app looks fine in its
own logs right up to the moment it dies — because it never gets to log
anything: the kernel kills it instantly.

**COMMAND**
```bash
kubectl describe pod <POD> -n orders | grep -A6 "Last State"
kubectl get pod <POD> -n orders -o jsonpath='{.spec.containers[0].resources}'
kubectl top pods -n orders
```

**OUTPUT TO LOOK FOR**
```
Last State: Terminated
  Reason: OOMKilled
  Exit Code: 137
```
**Exit 137 = 128 + 9 (SIGKILL).** Memorise it. It means the kernel's OOM killer
acted, not the application.

**ROOT CAUSE**
The container's working set exceeded `resources.limits.memory`. Two very
different underlying situations, and you must tell them apart:
- **The limit is too low** — the app legitimately needs more. Raise it.
- **The app leaks** — usage grows without bound. Raising the limit only delays
  the crash; fix the leak.

`kubectl top` over time, or the memory graph on the dashboard, distinguishes
them: a sawtooth that plateaus is normal; a monotonic climb is a leak.

**FIX**
```bash
helm upgrade ... --set resources.limits.memory=256Mi
```

**VALIDATION**
```bash
kubectl top pods -n orders           # usage stabilises below the new limit
kubectl get pods -n orders           # restarts stop
```

**PREVENTION**
- Set the limit from observed peak plus headroom, never from a round number.
- Set `requests.memory == limits.memory` for Guaranteed QoS, so the pod is last
  to be evicted under node pressure.
- Alert on `container_memory_working_set_bytes / limit > 0.85` — that fires
  *before* the kill, which is the entire point.
- Load-test with realistic payload sizes.

**INTERVIEW QUESTION**
*"What is exit code 137, and how do you tell a too-small limit from a leak?"*
Strong answer covers 128+SIGKILL, the fact that memory is incompressible (unlike
CPU, which throttles rather than kills), and uses the shape of the memory curve
over time to distinguish the two. Bonus: mentions that OOMKill can also come
from *node* memory pressure, not just the container limit.

---

## 05 Readiness failure — Running, Ready 0/1, zero endpoints

**SYMPTOM**
`kubectl get pods` shows `Running` with `READY 0/1`. Zero restarts. The service
returns connection errors, yet nothing looks "crashed".

**COMMAND**
```bash
kubectl get pods -n orders
kubectl get endpoints orders-api -n orders
kubectl describe pod <POD> -n orders | grep -A5 Readiness
```

**OUTPUT TO LOOK FOR**
```
READY: 0/1   STATUS: Running   RESTARTS: 0
ENDPOINTS: <none>
Warning  Unhealthy  Readiness probe failed: HTTP probe failed with statuscode: 503
```

**ROOT CAUSE**
The readiness probe fails, so the endpoints controller removes the pod from the
Service. This is Kubernetes **working correctly** — it is refusing to send
traffic to a pod that says it cannot serve. The real question is *why* the app
reports not-ready: a dependency is down, a cache has not warmed, or the probe
path/port is simply wrong.

**Readiness vs liveness is the distinction to be crisp about:**
readiness failing = no traffic, pod kept alive.
liveness failing = container restarted.

**FIX**
```bash
kubectl logs <POD> -n orders --tail=50     # why does the app say not-ready?
curl localhost:8080/ready                  # what does it actually return?
helm upgrade ... --set faultInjection.failReadiness=false
```

**VALIDATION**
```bash
kubectl get pods -n orders                 # 1/1
kubectl get endpoints orders-api -n orders # the pod IP is listed
```

**PREVENTION**
- Readiness must reflect *real* serving capability, including critical deps.
- Liveness must **not** check dependencies (see scenario 06).
- Alert on `kube_endpoint_address_available == 0`.
- PDB + `maxUnavailable: 0` so a rollout cannot remove every ready pod at once.

**INTERVIEW QUESTION**
*"A pod is Running but 0/1 Ready for ten minutes. What is happening to traffic,
and what do you check?"*
Strong answer: it receives none — it is out of Endpoints. Then: read the app
logs for the readiness reason, confirm the probe path/port/scheme are right,
and check whether a shared dependency is failing (if every pod is 0/1
simultaneously, suspect the dependency, not the pods).

---

## 06 Liveness too aggressive — healthy app restarted in a loop

**SYMPTOM**
Restart count climbs on a service that, whenever you catch it running, behaves
perfectly. Restarts often cluster during traffic peaks or slow-dependency
windows.

**COMMAND**
```bash
kubectl describe pod <POD> -n orders | grep -B2 -A8 Liveness
kubectl get events -n orders | grep -i unhealthy
kubectl logs <POD> -n orders --previous
```

**OUTPUT TO LOOK FOR**
```
Liveness probe failed: HTTP probe failed with statuscode: 500
Container orders-api failed liveness probe, will be restarted
Last State: Terminated  Reason: Error  Exit Code: 143
```
Exit **143** = 128 + 15 (SIGTERM) — Kubernetes asked it to stop. Contrast with
137 (SIGKILL/OOM) and 1 (the app chose to exit).

**ROOT CAUSE**
The liveness probe is failing on a process that is actually alive. Classic
causes: the probe endpoint checks a **database** (so a slow dependency restarts
every pod at once, converting a partial outage into a total one), the timeout is
shorter than a normal GC pause, or `failureThreshold` is 1 on a service with
occasional latency spikes.

**FIX**
Make liveness dumb and forgiving; put dependency checks in readiness only.
```bash
helm upgrade ... \
  --set probes.liveness.failureThreshold=3 \
  --set probes.liveness.periodSeconds=10 \
  --set probes.liveness.timeoutSeconds=3
```

**VALIDATION**
```bash
kubectl get pods -n orders -w    # restart count holds steady under load
```

**PREVENTION**
- **Liveness answers one question: is the process wedged?** Nothing else.
- Use a startup probe for slow boots instead of a long `initialDelaySeconds`.
- Alert on restart *rate*, which catches this pattern; a raw restart count does
  not.

**INTERVIEW QUESTION**
*"Why should a liveness probe never check the database?"*
Strong answer: because a database blip then restarts every replica
simultaneously — you have coupled your availability to your dependency's
availability and amplified the outage. Readiness is the correct place for
dependency checks: it sheds traffic without destroying the pods that would
otherwise recover.

---

## 07 Startup probe too short — slow boot killed before it finishes

**SYMPTOM**
Pods never become Ready and restart forever, but only on *first* start.
Ironically, more replicas make it worse (thundering herd on a cold cache).

**COMMAND**
```bash
kubectl describe pod <POD> -n orders | grep -A5 Startup
kubectl logs <POD> -n orders --previous
```

**OUTPUT TO LOOK FOR**
```
Startup probe failed: Get "http://10.244.1.5:8080/startup": dial tcp: connection refused
Container failed startup probe, will be restarted
```

**ROOT CAUSE**
`failureThreshold × periodSeconds` is less than the app's real boot time, so the
container is killed mid-boot and never gets far enough to pass. The budget here
is 10 × 2s = 20s against a 90s boot.

**FIX**
Widen the startup budget to comfortably exceed the *worst observed* boot time.
```bash
helm upgrade ... --set probes.startup.failureThreshold=60   # 60 x 2s = 120s
```

**VALIDATION**
```bash
kubectl get pods -n orders -w    # reaches 1/1 without restarting
```

**PREVENTION**
- Measure real boot time, including cold caches and JIT/JVM warmup, then set the
  budget generously above the worst case.
- Prefer a startup probe over a large `initialDelaySeconds`: a startup probe
  lets a *fast* boot become Ready immediately, whereas
  `initialDelaySeconds: 120` makes every pod wait 120 seconds.
- Reduce boot time itself — lazy-load, warm caches asynchronously.

**INTERVIEW QUESTION**
*"When would you use a startup probe instead of initialDelaySeconds?"*
Strong answer: when boot time varies. A startup probe suspends liveness and
readiness until the app is up, so it tolerates a slow worst case *without*
penalising the common fast case, and it lets liveness stay aggressive
afterwards — which `initialDelaySeconds` cannot do.

---

## 08 Missing Secret — required config absent

**SYMPTOM**
Either `CreateContainerConfigError` (Kubernetes cannot construct the container),
or — as in this app — the container starts and immediately exits with a precise
error message.

**COMMAND**
```bash
kubectl get pods -n orders
kubectl describe pod <POD> -n orders | tail -15
kubectl logs <POD> -n orders --previous
kubectl get secrets -n orders
```

**OUTPUT TO LOOK FOR**
```
Error: secret "orders-api-secrets-typo" not found
```
or, from the application:
```
{"severity":"ERROR","message":"required env ORDERS_DB_DSN is not set - check the
ConfigMap and Secret referenced by the Deployment (envFrom)"}
```

**ROOT CAUSE**
The Deployment references a Secret (or key) that does not exist. Usually a
typo, a missing bootstrap step in a fresh namespace, or a Secret that lives in a
different namespace — **Secrets are namespaced and cannot be referenced across
namespaces.**

Note the design choice: `secretRef` uses `optional: true`, so the pod *starts*
and the application produces a clear, greppable error. That is deliberately
better than `CreateContainerConfigError`, which tells you a Secret is missing
but not which key the app actually needed.

**FIX**
```bash
kubectl create secret generic orders-api-secrets -n orders \
  --from-literal=ORDERS_DB_DSN='postgresql://user:pass@host:5432/orders'
kubectl rollout restart deployment/orders-api -n orders
```

**VALIDATION**
```bash
kubectl get pods -n orders                       # Running 1/1
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api | head
```

**PREVENTION**
- Secret Manager + CSI driver, or External Secrets Operator: the value is never
  a hand-created Kubernetes object that someone can forget.
- Validate required keys in CI against the chart.
- Never `helm --set` a secret value: it lands in shell history and in the Helm
  release, recoverable via `helm get values` for every past revision.

**INTERVIEW QUESTION**
*"How do you manage secrets for a GKE workload, and why not Kubernetes Secrets
directly?"*
Strong answer: base64 is encoding, not encryption; anyone with `get secret` RBAC
reads it in plaintext; and etcd holds it. Prefer Secret Manager with the CSI
driver or External Secrets, authenticated by **Workload Identity** so there is
no static key anywhere. Mention rotation and audit logging as the deciding
factors.

---

## 09 Wrong ConfigMap value — deploys clean, behaves wrong

**SYMPTOM**
Nothing is broken. Every pod is Ready, zero restarts, the deploy is green — and
behaviour is subtly wrong. Here: logs go silent (`LOG_LEVEL=CRITICAL`) and
graceful shutdown is disabled (`SHUTDOWN_DRAIN_SECONDS=0`), which shows up later
as 502s during the *next* rollout.

**COMMAND**
```bash
kubectl get configmap orders-api-config -n orders -o yaml
kubectl exec <POD> -n orders -- env | sort | grep -E 'LOG_LEVEL|SHUTDOWN'
kubectl rollout history deployment/orders-api -n orders
helm get values orders-api -n orders
```

**OUTPUT TO LOOK FOR**
```
LOG_LEVEL: CRITICAL
SHUTDOWN_DRAIN_SECONDS: "0"
```

**ROOT CAUSE**
A configuration value that is syntactically valid and semantically wrong. This
class is dangerous precisely because **every health signal stays green** — no
probe, no alert and no rollout check will catch it.

There is a second trap here worth internalising: **editing a ConfigMap does not
restart pods.** Without a mechanism to force a rollout, a config change appears
to deploy while every running pod keeps the old value. This chart solves it by
hashing the rendered ConfigMap into a pod annotation
(`checksum/config`), which changes the pod template and triggers a rolling
update.

**FIX**
```bash
helm upgrade ... --set config.LOG_LEVEL=INFO --set config.SHUTDOWN_DRAIN_SECONDS=5
```

**VALIDATION**
```bash
kubectl exec <POD> -n orders -- env | grep LOG_LEVEL
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=5   # INFO lines return
```

**PREVENTION**
- Schema-validate config in CI (allowed enum values, ranges).
- The `checksum/config` annotation pattern, so config changes actually roll.
- Diff config between environments before promoting.
- A smoke test that asserts *behaviour*, not just HTTP 200.

**INTERVIEW QUESTION**
*"You changed a ConfigMap and ran `kubectl apply`. Pods still use the old value.
Why?"*
Strong answer: a ConfigMap consumed via `env`/`envFrom` is injected at container
start and never updated; only *volume-mounted* ConfigMaps update in place (with
kubelet sync lag, and the app still has to re-read the file). The standard fix
is to force a new pod template — the checksum-annotation pattern — or
`kubectl rollout restart`.

---

## 10 Wrong version live — Helm says 2.4.18, pods serve 2.4.17

**SYMPTOM**
The pipeline is green. `helm list` shows the new version. The change-cause says
2.4.18. Users report the new feature is missing, and the bug you just fixed is
still happening.

**COMMAND**
```bash
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.18
helm list -n orders
kubectl get deployment orders-api -n orders -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl get pods -n orders -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}'
curl -s localhost:8080/version
```

**OUTPUT TO LOOK FOR**
```
Helm appVersion : 2.4.18
Deployment image: orders-api:2.4.17      <-- the disagreement
/version reports: 2.4.17
```

**ROOT CAUSE**
Helm metadata and the actual image reference are **independent**. Bumping
`appVersion` changes what Helm *reports*; it does not change what runs. Related
real-world variants, all producing the same symptom:
- a **mutable tag** was overwritten, so `:2.4.17` now points at different code;
- `imagePullPolicy: IfNotPresent` + a mutable tag = the node reuses a cached
  layer and never contacts the registry;
- CI pushed to a different registry path than the Deployment pulls from;
- the rollout is half-finished, so *some* pods are new — the worst version,
  because behaviour is intermittent and averaged metrics hide it.

**FIX**
```bash
helm upgrade ... --set image.tag=2.4.18
# strongest guarantee - pin the digest:
helm upgrade ... --set image.digest=sha256:<digest>
```

**VALIDATION**
```bash
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.18
```
It must pass at **every** layer, ending with the application's own `/version`.

**PREVENTION**
- **Immutable tags** in Artifact Registry (this repo's Terraform enforces it).
- Deploy by **digest** in production.
- A `/version` endpoint that reports the build's real identity, baked in at
  build time via `--build-arg`.
- A pipeline gate that fails the deploy when `/version` disagrees with the
  requested version.

**INTERVIEW QUESTION**
*"The pipeline says SUCCESS but the old version is running. Walk me through
finding out why."*
This is the flagship question of this whole project. Strong answer walks the
layers in order — git tag → registry digest → Helm release → Deployment spec →
ReplicaSet → pod `spec.image` vs `status.imageID` → the app's own `/version` —
and specifically calls out `imageID` as the ground truth at the Kubernetes
layer, because it is the resolved digest rather than the requested tag.

---

## 11 PDB blocks drain — node drain hangs forever

**SYMPTOM**
`kubectl drain` never completes. Cluster upgrades stall. The autoscaler cannot
remove an underused node, so you keep paying for it.

**COMMAND**
```bash
kubectl get pdb -n orders
kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data --timeout=60s
kubectl get events -n orders | grep -i evict
```

**OUTPUT TO LOOK FOR**
```
NAME         MIN AVAILABLE   ALLOWED DISRUPTIONS
orders-api   2               0                      <-- zero is the problem

error when evicting pod "orders-api-xxx":
  Cannot evict pod as it would violate the pod's disruption budget.
```

**ROOT CAUSE**
`minAvailable` equals the replica count, so **no** pod may ever be voluntarily
evicted. `ALLOWED DISRUPTIONS: 0` states it outright.

A PDB governs **voluntary** disruptions only — drains, upgrades, autoscaler
scale-down. It does nothing about a node hard-failing, an OOM kill or a crash.
People frequently believe a PDB protects availability in general; it does not.

**FIX**
```bash
helm upgrade ... --set podDisruptionBudget.minAvailable=1
# or raise replicas so the budget has slack
helm upgrade ... --set replicaCount=3
```

**VALIDATION**
```bash
kubectl get pdb -n orders          # ALLOWED DISRUPTIONS >= 1
kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data   # completes
kubectl uncordon <NODE>
```

**PREVENTION**
- Keep `minAvailable` strictly below `replicaCount` — or express it as a
  percentage (`maxUnavailable: 25%`) so it scales with the deployment.
- Test a node drain as part of migration validation, before you need it at 02:00
  during an upgrade.
- Alert on drains exceeding a time budget.

**INTERVIEW QUESTION**
*"A node drain has been stuck for 20 minutes during a cluster upgrade. Why?"*
Strong answer: check PDBs first — `ALLOWED DISRUPTIONS: 0` is the tell. Then
explain the voluntary/involuntary distinction, note that a single-replica
deployment with `minAvailable: 1` is permanently undrainable, and mention that
unmanaged (bare) pods are never evicted automatically either.

---

## 12 Workload Identity 403 — KSA/GSA binding mismatch

> **GKE only.** kind has no metadata server, so on a local cluster study the
> binding rather than the error.

**SYMPTOM**
The app starts and serves traffic normally, but every call to a Google API
(Secret Manager, Cloud Storage, Pub/Sub) returns 403. Nothing in Kubernetes
looks wrong.

**COMMAND**
```bash
kubectl get sa orders-api -n orders -o yaml
gcloud iam service-accounts get-iam-policy <GSA_EMAIL>
kubectl exec <POD> -n orders -- \
  curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email"
```

**OUTPUT TO LOOK FOR**
```
annotations:
  iam.gke.io/gcp-service-account: wrong-sa@wrong-project.iam.gserviceaccount.com

# and the GSA's IAM policy does NOT contain:
serviceAccount:PROJECT.svc.id.goog[orders/orders-api]
```

**ROOT CAUSE**
Workload Identity needs **two** halves that must agree exactly:
1. The **KSA annotation** pointing at the Google service account.
2. An **IAM policy binding** on that GSA granting
   `roles/iam.workloadIdentityUser` to
   `serviceAccount:PROJECT.svc.id.goog[NAMESPACE/KSA_NAME]`.

Miss either, or mistype the namespace or KSA name, and you get a 403 whose
message names neither side of the mismatch. It is also easy to forget that
`workload_identity_config` must be enabled on the cluster **and**
`GKE_METADATA` set on the node pool.

**FIX**
```bash
kubectl annotate sa orders-api -n orders \
  iam.gke.io/gcp-service-account=<CORRECT_GSA> --overwrite

gcloud iam service-accounts add-iam-policy-binding <CORRECT_GSA> \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:PROJECT.svc.id.goog[orders/orders-api]"

kubectl rollout restart deployment/orders-api -n orders
```

**VALIDATION**
The metadata query above returns the **correct** GSA email, and the Google API
call succeeds.

**PREVENTION**
- Create both halves in the same Terraform module (as
  `terraform/modules/iam/main.tf` does), so they cannot drift.
- Assert the namespace/KSA in one place and reference it from both sides.
- A startup self-check that calls one Google API and fails loudly.

**INTERVIEW QUESTION**
*"Explain Workload Identity and why it is better than a service-account key."*
Strong answer: the KSA↔GSA binding, the metadata server issuing short-lived
tokens, and the fact that **no key material ever exists** — so nothing can be
committed to git, leaked in logs, or need rotating. A JSON key never expires,
works from anywhere on earth, and is the most common root cause of real GCP
compromises.

---

## 13 HPA will not scale — metrics show `<unknown>`

**SYMPTOM**
Load rises, latency rises, replica count does not move. `kubectl get hpa` shows
`TARGETS: <unknown>/70%`.

**COMMAND**
```bash
kubectl get hpa -n orders
kubectl describe hpa orders-api -n orders
kubectl top pods -n orders
kubectl get deployment orders-api -n orders -o jsonpath='{.spec.template.spec.containers[0].resources}'
```

**OUTPUT TO LOOK FOR**
```
TARGETS: <unknown>/70%
Conditions:
  ScalingActive  False  FailedGetResourceMetric
  failed to get cpu utilization: missing request for cpu
```

**ROOT CAUSE**
HPA CPU targets are a **percentage of the CPU request**. With no
`resources.requests.cpu`, there is no denominator and the HPA cannot compute
anything. It fails open — it simply never scales.

The other common cause of the same display is metrics-server not installed or
not Ready. `kubectl top pods` distinguishes them in one command: if `top` works,
metrics-server is fine and the problem is the missing request.

Further reasons an HPA "does not scale" even with valid metrics: already at
`maxReplicas`; new pods stuck `Pending` (no cluster capacity); the scale-down
stabilisation window still open; or the metric genuinely below target because
the bottleneck is I/O rather than CPU.

**FIX**
```bash
helm upgrade ... --set resources.requests.cpu=50m
```

**VALIDATION**
```bash
kubectl get hpa -n orders          # TARGETS shows a real percentage
./scripts/load-test.sh -n orders   # replicas increase under load
```

**PREVENTION**
- Always set CPU requests — the HPA, the scheduler and QoS all depend on them.
- Alert on the HPA's `ScalingActive=False` condition.
- Verify autoscaling with a load test as part of migration validation, not
  during the first real traffic peak.

**INTERVIEW QUESTION**
*"An HPA is not scaling under load. Give me your checklist."*
Strong answer, in order: `kubectl top` (is metrics-server alive?) → is
`requests.cpu` set? → `describe hpa` conditions → already at max? → are new pods
Pending? → is CPU actually the constrained resource? Bonus: explains that
utilisation is computed against the request, not the limit and not node
capacity.

---

## 14 Service has no endpoints — selector matches nothing

**SYMPTOM**
Every pod is `Running` and `1/1`. The Deployment is perfectly healthy. And all
traffic to the Service fails with connection refused or timeout.

**COMMAND**
```bash
kubectl get endpoints orders-api -n orders
kubectl get svc orders-api -n orders -o jsonpath='{.spec.selector}'
kubectl get pods -n orders --show-labels
```

**OUTPUT TO LOOK FOR**
```
NAME         ENDPOINTS   AGE
orders-api   <none>      10m          <-- the entire diagnosis

Service selector: {"app.kubernetes.io/name":"orders-api-typo", ...}
Pod labels:       app.kubernetes.io/name=orders-api, ...
```

**ROOT CAUSE**
A Service routes to pods by **label selector**, not by name. If the selector
matches nothing, the Service still exists, still has a ClusterIP, still accepts
connections — and drops every one of them. There is no error anywhere; the
Service is doing exactly what it was told.

The second cause of empty endpoints is subtler and more common in practice: the
selector matches, but **no matching pod is Ready** (scenario 05). Only Ready
pods appear in Endpoints.

**FIX**
```bash
kubectl patch svc orders-api -n orders --type=merge \
  -p '{"spec":{"selector":{"app.kubernetes.io/name":"orders-api","app.kubernetes.io/instance":"orders-api"}}}'
```

**VALIDATION**
```bash
kubectl get endpoints orders-api -n orders     # pod IPs appear
curl localhost:8080/health                     # via port-forward
```

**PREVENTION**
- Generate Service selectors and pod labels from **one** Helm helper —
  `orders-api.selectorLabels` in `_helpers.tpl` — so they cannot diverge.
- Alert on `kube_endpoint_address_available == 0`: this is the single highest-value
  alert for "healthy pods, dead service".
- Smoke-test through the Service after every deploy, never against a pod IP.

**INTERVIEW QUESTION**
*"Pods are healthy, the Service returns nothing. Where do you look?"*
Strong answer: `kubectl get endpoints` first — it collapses the whole problem to
one line. Empty endpoints means either a selector mismatch or no Ready pod;
compare `svc.spec.selector` against `pod.metadata.labels` to tell which. Bonus:
mentions `targetPort` vs `containerPort` mismatch as a third cause where
endpoints exist but connections still fail.

---

## 15 Bad release — elevated HTTP 500s, requires rollback

**SYMPTOM**
Deploy succeeded. All pods Ready. Every probe green. Users report intermittent
errors. Roughly 30% of requests return 500 — and because it is intermittent,
retries mask it and averaged dashboards look almost normal.

**COMMAND**
```bash
./scripts/health-check.sh -n orders
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=100 | grep ERROR
curl -s localhost:8080/metrics | grep 'http_requests_total.*status="500"'
helm history orders-api -n orders
```

**OUTPUT TO LOOK FOR**
```
14/20 succeeded (70%) - USERS ARE SEEING ERRORS
{"severity":"ERROR","message":"unhandled error","request_id":"...","status":500}
http_requests_total{method="GET",path="/api/orders",status="500"} 47.0
```

**ROOT CAUSE**
The application returns 500 on real business requests while its **health
endpoints keep returning 200**. Kubernetes therefore sees a perfectly healthy
deployment. This is the single most important lesson in the lab: *probe health
is not user-facing correctness.* Only request-level metrics or logs reveal it.

**FIX — roll back first, investigate second.**
```bash
./scripts/rollback.sh -n orders
# or
helm rollback orders-api <PREVIOUS_REVISION> -n orders --wait
```
Stopping user impact takes priority over understanding the bug. You can debug a
bad image at leisure once it is out of production.

**VALIDATION**
```bash
./scripts/health-check.sh -n orders             # back to 20/20
./scripts/verify-version.sh -n orders -r orders-api -v <ROLLED_BACK_VERSION>
```

**PREVENTION**
- Alert on the **5xx rate**, not on pod health — this is the alert that would
  have caught it in 60 seconds.
- Canary or progressive delivery: expose 5% of traffic first.
- Automated smoke tests against *business* endpoints post-deploy.
- Error-budget policy: a burn rate this steep should page immediately.
- `helm upgrade --atomic` so a failing rollout self-reverts.

**INTERVIEW QUESTION**
*"GitHub Actions reports SUCCESS. Users are getting intermittent 500s. What is
your first move?"*
This is the closing simulation of the whole project. Strong answer: quantify
first (what percentage, which endpoints, since when — is it *actually*
correlated with the deploy?), check whether the fleet is mixed-version, then
**roll back to stop impact** before root-causing. It explicitly does not start
by reading code. It also notes that "all pods Ready" is compatible with a total
functional outage, which is exactly why 5xx-rate alerting exists.

---

## Where these map in the rest of the repo

| Scenario | Runbook |
|---|---|
| 01, 02, 03, 04, 05, 06, 07, 08 | [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) |
| 10 | [docs/VERSION_VERIFICATION.md](../docs/VERSION_VERIFICATION.md) |
| 13 | [docs/AUTOSCALING.md](../docs/AUTOSCALING.md) |
| 15 | [ROLLBACK_RUNBOOK.md](../ROLLBACK_RUNBOOK.md), [docs/INCIDENT_HTTP_500.md](../docs/INCIDENT_HTTP_500.md) |
| 12 | [SECURITY.md](../SECURITY.md) |
| all | [INTERVIEW_GUIDE.md](../INTERVIEW_GUIDE.md), [docs/INTERVIEW_QUESTIONS.md](../docs/INTERVIEW_QUESTIONS.md) |

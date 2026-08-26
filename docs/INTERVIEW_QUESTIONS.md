# 100 Senior DevOps Interview Questions

Scenario-based, weighted toward what you actually get asked for a GKE
migration/support role. Every question has the answer a senior gives, the
commands you'd run, a likely follow-up, and the mistake that costs you the offer.

**How to use this:** cover the answer, say yours out loud, then compare. Reading
these is worth about a tenth of saying them.

| Section | Questions |
|---|---|
| [Kubernetes fundamentals & troubleshooting](#kubernetes-fundamentals--troubleshooting) | 1–18 |
| [Deployments, rollouts, rollback](#deployments-rollouts-rollback) | 19–28 |
| [GKE specifics](#gke-specifics) | 29–40 |
| [GCP, IAM, security](#gcp-iam-security) | 41–52 |
| [Terraform & IaC](#terraform--iac) | 53–62 |
| [Docker, images, registry](#docker-images-registry) | 63–71 |
| [CI/CD & GitHub Actions](#cicd--github-actions) | 72–80 |
| [Helm](#helm) | 81–86 |
| [Monitoring, logging, alerting](#monitoring-logging-alerting) | 87–93 |
| [Migration](#migration) | 94–97 |
| [Incident response & judgement](#incident-response--judgement) | 98–100 |

---

## Kubernetes fundamentals & troubleshooting

### 1. A pod is in CrashLoopBackOff. Walk me through your first five commands.

**Answer.** `kubectl get pods` to confirm the state and restart count.
`kubectl describe pod` to read the exit code and reason from `Last State` — that
tells me whether it's an application exit, an OOM kill (137), or a SIGTERM (143).
Then **`kubectl logs POD --previous`**, which is the one that matters: the
current container has just started and hasn't failed yet, so the reason it died
is in the previous one. Then `kubectl get events` for anything the platform is
saying. Then the resource spec if the exit code suggests OOM.

I'd also note the backoff grows 10s → 20s → 40s, capped at 5 minutes — so after
a fix, it can take up to five minutes to visibly take effect. Don't conclude your
fix failed too early.

**Commands.**
```bash
kubectl get pods -n orders
kubectl describe pod POD -n orders | grep -A6 "Last State"
kubectl logs POD -n orders --previous
kubectl get events -n orders --sort-by=.lastTimestamp
kubectl get pod POD -n orders -o jsonpath='{.spec.containers[0].resources}'
```

**Follow-up:** *"The previous logs are empty. Now what?"* → The container is
dying before it writes anything: a bad entrypoint, a missing binary, or an
immediate segfault. Check `describe` for the command, and try
`kubectl run --rm -it` with the same image and an overridden command to poke at
the filesystem.

**Common mistake.** Forgetting `--previous` and concluding "the logs show
nothing". It's the single most common wasted five minutes in Kubernetes
debugging.

---

### 2. What is exit code 137, and how is it different from 143?

**Answer.** Both are 128 + signal. **137 = 128 + 9 (SIGKILL)** — something killed
the process outright, almost always the kernel OOM killer because the container
exceeded its memory limit, or kubelet after the termination grace period expired.
**143 = 128 + 15 (SIGTERM)** — Kubernetes asked it to stop politely: a liveness
probe failure, an eviction, or a normal rolling update.

The practical difference: 137 means the process got no chance to log anything, so
its own logs end mid-sentence. 143 means it was asked to shut down and you should
check whether it drained cleanly.

**Follow-up:** *"Your app calls `sys.exit(1)` but the container reports exit 3.
Why?"* → A supervisor or ASGI server sits between the code and PID 1. Uvicorn
catches `SystemExit` during startup and exits with its own code. So application
exit codes aren't reliable when anything wraps the process — but 137 and 143
originate *outside* it and always are.

**Common mistake.** Treating 137 as "the app crashed". It didn't crash; it was
executed.

---

### 3. Explain liveness, readiness and startup probes. Why three?

**Answer.** They answer three different questions.

**Startup** — has it finished booting? While it's failing, liveness and readiness
are suspended entirely. That's what lets a slow-booting app coexist with an
aggressive liveness probe.

**Liveness** — is the process wedged? Failing it **restarts the container**, so
it should be forgiving and dumb.

**Readiness** — should traffic come here right now? Failing it **removes the pod
from Service Endpoints** without killing it. That's cheap, so it can be twitchy,
and it *should* reflect dependencies.

**Follow-up:** *"Why should liveness never check the database?"* → Because a
database blip would then restart every replica simultaneously. You've coupled
your availability to your dependency's and amplified a partial outage into a
total one. Readiness is the right place: it sheds traffic without destroying the
pods that would otherwise recover.

**Common mistake.** Pointing all three at the same endpoint with the same
thresholds. It defeats the purpose of having three.

---

### 4. A pod shows `Running` but `0/1 Ready`. What's happening to traffic?

**Answer.** It's receiving none. Readiness is failing, so the endpoints
controller has removed it from the Service. That's Kubernetes working correctly —
it's refusing to route to a pod that says it can't serve.

I'd check `kubectl get endpoints` to confirm, then `describe pod` for the probe
failure message, then the app logs for *why* it reports not-ready. If **every**
replica is 0/1 at the same moment, I'd suspect the shared dependency rather than
the pods.

**Commands.**
```bash
kubectl get endpoints orders-api -n orders
kubectl describe pod POD -n orders | grep -A5 Readiness
kubectl logs POD -n orders --tail=50
```

**Follow-up:** *"It's been 0/1 for ten minutes with zero restarts. Why no
restarts?"* → Because readiness failure doesn't restart anything. Only liveness
does. That combination — not Ready, not restarting — tells you liveness passes
and readiness doesn't, which usually means a dependency check.

**Common mistake.** Assuming `Running` means serving.

---

### 5. A pod is `Pending` and `kubectl logs` returns nothing. Why?

**Answer.** Because there is no container. `Pending` means the **scheduler**
couldn't place the pod — kubelet was never involved, so nothing has started and
there's nothing to log. The answer is in `kubectl describe pod`, in the events at
the bottom.

The message is specific and worth reading verbatim: `Insufficient cpu` is a
capacity problem, `had untolerated taint` is a taint mismatch, `didn't match node
affinity` is a selector problem, `unbound PersistentVolumeClaims` is storage.

**The subtlety:** scheduling works on **requests**, not usage. A cluster idling
at 5% real CPU can be 100% requested and completely unschedulable.

**Commands.**
```bash
kubectl describe pod POD -n orders | tail -20
kubectl describe nodes | grep -A8 "Allocated resources"
kubectl top nodes
```

**Follow-up:** *"`describe nodes` shows 95% CPU allocated but `top nodes` shows
10% used. Explain."* → Requests are reservations, not consumption. Someone has
over-requested. Right-size the requests using observed usage.

**Common mistake.** Going to logs first. There are none.

---

### 6. Pods are healthy but the Service returns nothing. Where do you look?

**Answer.** `kubectl get endpoints` — first, always. That one line collapses the
whole problem.

Empty endpoints means exactly one of two things: the Service's label selector
matches no pods, or no matching pod is **Ready** (only Ready pods appear in
Endpoints). Comparing `svc.spec.selector` against pod labels tells you which.

If endpoints *exist* and connections still fail, it's a `targetPort` mismatch —
the Service points at a port nothing is listening on.

**Commands.**
```bash
kubectl get endpoints orders-api -n orders
kubectl get svc orders-api -n orders -o jsonpath='{.spec.selector}'
kubectl get pods -n orders --show-labels
```

**Follow-up:** *"How would you prevent this?"* → Generate the Service selector
and pod labels from one Helm helper so they can't diverge, and alert on
`kube_endpoint_address_available == 0`.

**Common mistake.** Debugging DNS or network policy before checking endpoints.

---

### 7. What's the difference between `requests` and `limits`?

**Answer.** **Requests** are what the scheduler reserves — they decide which node
the pod fits on and the guaranteed floor under contention. **Limits** are the
hard ceiling.

The critical asymmetry: **CPU is compressible, memory is not.** Exceeding the CPU
limit *throttles* the container — it gets slower. Exceeding the memory limit gets
it **OOM-killed instantly**, exit 137, with no chance to log.

That's why a CPU limit well above the request is fine, and a memory limit close
to actual usage is dangerous.

**Follow-up:** *"What QoS classes exist and why care?"* → `Guaranteed` (requests
== limits for both), `Burstable` (requests set, limits higher), `BestEffort`
(nothing set). Under node memory pressure, BestEffort is evicted first,
Guaranteed last. Setting `requests.memory == limits.memory` buys you Guaranteed
QoS, which is why this project does it.

**Common mistake.** Setting a CPU limit equal to the request "for consistency",
then wondering why a latency-sensitive service is being throttled.

---

### 8. A container is OOMKilled. How do you tell a too-small limit from a leak?

**Answer.** The shape of the memory curve over time. A sawtooth that rises and
plateaus is normal allocation and GC — the limit is simply too low, raise it. A
line that climbs monotonically and never returns is a leak, and raising the limit
only delays the crash.

I'd also check whether it's node-level memory pressure rather than the container
limit — `kubectl describe node | grep MemoryPressure`.

**Commands.**
```bash
kubectl describe pod POD -n orders | grep -A6 "Last State"
kubectl top pods -n orders
kubectl get pod POD -n orders -o jsonpath='{.spec.containers[0].resources}'
```

**Follow-up:** *"How would you catch this before the kill?"* → Alert at 85% of
the limit. Alerting on an OOMKill tells you about an outage you failed to
prevent; 85% gives you time to act.

**Common mistake.** Doubling the limit and calling it fixed, without looking at
the curve.

---

### 9. What's a PodDisruptionBudget actually protecting against?

**Answer.** **Voluntary** disruptions only — node drains, cluster upgrades,
cluster-autoscaler scale-down. It does nothing about a node hard-failing, an OOM
kill, or a crash. Those are involuntary and no budget applies.

People often believe a PDB protects availability in general. It doesn't; it
protects against *you and your platform* removing pods.

**The trap:** `minAvailable` equal to `replicaCount` means `ALLOWED DISRUPTIONS:
0` — no pod may ever be evicted, so drains hang forever and cluster upgrades
stall. A single-replica Deployment with `minAvailable: 1` is permanently
undrainable.

**Commands.**
```bash
kubectl get pdb -n orders          # ALLOWED DISRUPTIONS must be >= 1
kubectl drain NODE --ignore-daemonsets --delete-emptydir-data
```

**Follow-up:** *"A node drain has been stuck for 20 minutes during an upgrade.
Why?"* → PDB first — `ALLOWED DISRUPTIONS: 0` is the tell. Also: unmanaged bare
pods are never evicted automatically either.

**Common mistake.** Setting `minAvailable` equal to replicas because it "sounds
safest". It's the one setting that guarantees you can't do maintenance.

---

### 10. Why do users see 502s during every deploy, and how do you fix it?

**Answer.** Pod deletion does two things **concurrently, not in order**: kubelet
starts terminating the container, and the endpoints controller removes the pod
from the Service. The second propagates through kube-proxy on every node and
isn't instant. So the container can be gone while nodes are still routing to it.

The fix is two-part. A **`preStop: sleep 5`** hook, which does nothing except
give endpoint removal time to propagate. And the application handling SIGTERM by
**flipping readiness off first, then draining** — so it stops being a target
before it stops working.

`terminationGracePeriodSeconds` must exceed preStop + drain + the longest
in-flight request, or Kubernetes SIGKILLs mid-request.

**Follow-up:** *"Why exec form rather than shell form in CMD?"* → With the shell
form, `sh` becomes PID 1 and swallows SIGTERM. The app never receives it, never
drains, and every rolling update ends in a 30-second SIGKILL.

**Common mistake.** Increasing the grace period without adding a preStop hook.
The race is in endpoint propagation, not shutdown duration.

---

### 11. What happens, in order, when you run `kubectl apply -f deployment.yaml`?

**Answer.** kubectl resolves the API endpoint and authenticates. The request hits
the API server, which runs authentication, authorisation (RBAC), then admission
controllers — mutating first (defaults, sidecar injection), then validating
(policy engines like Gatekeeper or Kyverno). If it passes, the object is
persisted to etcd.

Then controllers reconcile asynchronously: the Deployment controller creates or
updates a ReplicaSet; the ReplicaSet controller creates Pods; the scheduler binds
each Pod to a node; the kubelet on that node pulls the image and starts the
container; the endpoints controller adds the pod to the Service once it's Ready.

**The important part for a DevOps answer:** `kubectl apply` returning success
means *the object was persisted*, nothing more. Everything after is asynchronous,
which is exactly why `kubectl rollout status` exists.

**Follow-up:** *"Where would an admission webhook failure show up?"* → As a
rejection at apply time, or — on a private cluster — as a timeout, because the
control plane lives in a Google-managed VPC and may be firewalled from the
webhook port on your nodes.

**Common mistake.** Believing apply means running.

---

### 12. How does a Service actually route traffic to a pod?

**Answer.** The Service has a label selector. The endpoints controller watches
pods matching it and writes the **Ready** ones into an Endpoints (or
EndpointSlice) object. kube-proxy on every node watches those and programs
iptables or IPVS rules. A connection to the ClusterIP is DNAT'd to one of the
endpoint pod IPs.

Two consequences worth stating: **only Ready pods receive traffic**, and rule
propagation is not instantaneous, which is the root of the 502-on-deploy problem.

**Follow-up:** *"What does a headless Service do differently?"* → `clusterIP:
None`. No virtual IP, no kube-proxy rules — DNS returns the pod IPs directly.
Used for StatefulSets and any client that wants to do its own load balancing or
address individual pods.

**Common mistake.** Thinking the Service is a proxy process. It's a set of
packet-rewriting rules on every node.

---

### 13. `kubectl get pods` shows `CreateContainerConfigError`. What is it?

**Answer.** Kubernetes can't construct the container because something it
references doesn't exist — usually a Secret or ConfigMap, or a specific **key**
within one. `describe pod` names it exactly.

Common causes: a typo, a missing bootstrap step in a fresh namespace, or the
Secret existing in a *different namespace* — Secrets are namespaced and can't be
referenced across namespaces.

**Design note:** this project uses `optional: true` on its `secretRef`, so the
pod starts and the *application* fails fast with a message naming the exact
missing key. That's a better failure mode than a config error that tells you a
Secret is missing but not which key mattered.

**Commands.**
```bash
kubectl describe pod POD -n orders | tail -15
kubectl get secrets,cm -n orders
```

**Common mistake.** Confusing it with `ImagePullBackOff`. One is config, one is
the registry.

---

### 14. Explain `ImagePullBackOff`. What are the causes, in order?

**Answer.** The kubelet can't fetch the image. Four causes, and I'd check them in
this order because that's roughly their frequency:

1. **The tag doesn't exist** — a typo, or CI never actually pushed.
   `gcloud artifacts docker images describe` settles it in ten seconds: either it
   resolves to a digest or it doesn't.
2. **Authentication** — the node service account lacks
   `roles/artifactregistry.reader`.
3. **Wrong registry path** — pushed to one project or region, pulling from
   another.
4. **Network** — private nodes with neither Cloud NAT nor Private Google Access.

On kind there's a fifth: you forgot `kind load docker-image`.

**Follow-up:** *"The developer insists they pushed it."* → Then `images describe`
the exact tag. It's not an opinion; the registry either has it or doesn't.

**Common mistake.** Assuming it's always credentials. It's usually the tag.

---

### 15. What's the difference between a Deployment, a StatefulSet and a DaemonSet?

**Answer.** **Deployment** — interchangeable, stateless replicas. Random pod
names, any pod can serve any request, scaling is trivial.

**StatefulSet** — stable identity and storage. Ordinal names (`app-0`, `app-1`),
each keeps its PVC across restarts, ordered startup and shutdown. For databases,
Kafka, anything where "which instance am I" matters.

**DaemonSet** — one pod per node. Log collectors, node exporters, CNI plugins.

**Follow-up:** *"Why does force-deleting a StatefulSet pod carry more risk?"* →
`--grace-period=0 --force` removes the API object while the container may still
be running on the node. For a StatefulSet, the controller then creates a
replacement with the same identity and volume — two instances believing they own
the same state. Split-brain.

**Common mistake.** Reaching for a StatefulSet because the app has a database
*connection*. What matters is whether the **pod itself** holds state.

---

### 16. How would you debug a pod with no shell in its image?

**Answer.** `kubectl debug POD -it --image=busybox --target=CONTAINER`. That
attaches an ephemeral container sharing the target's process and network
namespaces, so you get tooling without rebuilding the image or weakening it.

This is the right answer for distroless images, and for hardened images like this
project's — non-root with a read-only root filesystem, where even if there is a
shell you can't install anything.

**Follow-up:** *"What if ephemeral containers are disabled?"* → Run a debug pod
on the same node with `hostNetwork`, or temporarily deploy a copy of the workload
with a debug image and an overridden command. Both are worse; both work.

**Common mistake.** Adding a shell and package manager to the production image
"for debugging". That's permanently expanding the attack surface to solve an
occasional problem.

---

### 17. What are taints and tolerations, and how do they differ from node affinity?

**Answer.** **Taints repel; affinity attracts.** A taint on a node says "don't
schedule here unless you tolerate this". A toleration on a pod says "I can live
with that taint" — it permits scheduling, it doesn't request it. Node affinity is
the pod expressing a preference or requirement about *where it wants to go*.

The distinction matters: a toleration alone won't put a pod on a tainted node; it
just stops it being excluded. To *target* those nodes you need affinity or a
nodeSelector as well.

Effects: `NoSchedule` (no new pods), `PreferNoSchedule` (soft), `NoExecute`
(evicts pods already running).

**Follow-up:** *"When would you use both together?"* → Dedicated node pools. Taint
the GPU pool so ordinary workloads stay off, and give GPU workloads both a
toleration and affinity so they actually land there.

**Common mistake.** Adding a toleration and expecting pods to move to those
nodes.

---

### 18. A node is `NotReady`. What do you do?

**Answer.** `kubectl describe node` and read the Conditions. `MemoryPressure` or
`DiskPressure` true means resource exhaustion — DiskPressure in particular starts
failing image pulls, which looks like a registry problem. `Ready: Unknown` means
the kubelet stopped reporting: a crash or a network partition.

On **Spot VMs** — this project's default — the most likely cause is preemption.
Google reclaimed the node with 30 seconds' notice. That's the trade for the
60–91% discount, and it's exactly why `minReplicas: 2`, a PDB, and topology
spread exist.

GKE node auto-repair handles most of this. If it doesn't: cordon, drain,
investigate or replace.

**Commands.**
```bash
kubectl get nodes
kubectl describe node NODE | grep -A10 Conditions
kubectl get pods -A -o wide --field-selector spec.nodeName=NODE
```

**Common mistake.** Deleting the node object without draining, orphaning
workloads that had somewhere better to go.
---

## Deployments, rollouts, rollback

### 19. GitHub Actions says the deployment succeeded, but users report the old version. How do you find out why?

**Answer.** This is the flagship question. Every layer reports on its own job and
every one can be truthfully green while the wrong code runs.

I walk the layers in order. **Registry** — does the tag exist, and what digest
does it resolve to *now*? **Helm** — status `deployed`, which revision, what
`appVersion`? **Deployment** — does `.spec.template.spec.containers[0].image`
reference what I expect? **Rollout completeness** — is `updatedReplicas ==
replicas`? If not, some traffic is hitting old pods right now. **Pods** — compare
`.spec.containers[0].image` (requested) against
`.status.containerStatuses[0].imageID` (the digest actually resolved and
started). **The application** — `curl /version`, sampled several times.

The likely causes: a mutable tag overwritten by a re-run; `IfNotPresent` reusing
a cached layer so the node never contacted the registry; only `appVersion`
changed, which alters what Helm reports and nothing about what runs; a
half-finished rollout; a registry-path mismatch; or a manual `kubectl` patch Helm
doesn't know about.

**Commands.**
```bash
gcloud artifacts docker images describe REGISTRY/orders-api:2.4.17 --format='value(image_summary.digest)'
kubectl get deployment orders-api -n orders -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl get pods -n orders -o custom-columns='POD:.metadata.name,SPEC:.spec.containers[0].image,RUNNING:.status.containerStatuses[0].imageID'
for i in $(seq 1 10); do curl -s localhost:8080/version | jq -r .application_version; done | sort | uniq -c
```

**Follow-up:** *"How do you make it impossible?"* → Immutable tags on the
registry, deploy by digest, bake build identity into the image at build time, and
gate the pipeline on a version check that fails when layers disagree.

**Common mistake.** Trusting `helm list`. It reports the release record, not
reality.

---

### 20. Explain `maxSurge` and `maxUnavailable`.

**Answer.** They bound a rolling update. **`maxSurge`** is how many extra pods
above the desired count may exist during the rollout; **`maxUnavailable`** is how
far below the desired count you're willing to drop.

`maxUnavailable: 0` with `maxSurge: 1` means capacity is preserved throughout —
a new pod must be Ready before an old one goes. That's the right default for
anything serving traffic. The cost is you need spare cluster capacity for the
extra pod, and on a small cluster the surge pod can sit `Pending`.

The opposite — `maxUnavailable: 1, maxSurge: 0` — needs no spare capacity but
deliberately runs degraded during every deploy.

**Follow-up:** *"When is `Recreate` the right strategy?"* → When two versions
can't coexist: an incompatible schema change, or a ReadWriteOnce volume that only
one pod can mount. It causes downtime, and that's accepted deliberately.

**Common mistake.** Leaving the 25%/25% defaults on a 2-replica deployment,
which rounds to running at half capacity during every deploy.

---

### 21. `helm rollback` vs `kubectl rollout undo` — which and why?

**Answer.** `helm rollback`, because it keeps Helm's state and reality in
agreement.

`kubectl rollout undo` changes the live Deployment but **not** the Helm release.
Helm now believes something different is deployed, and the next `helm upgrade`
silently re-applies the bad version. It's a legitimate break-glass option when
Helm is unavailable, but you must reconcile immediately afterwards.

Also: `rollout undo` can only reach ReplicaSets still retained by
`revisionHistoryLimit` — it can't go back further than that.

**Commands.**
```bash
helm history orders-api -n orders
helm rollback orders-api 7 -n orders --wait
```

**Follow-up:** *"Roll back one revision, always?"* → No. If the last three
releases were bad, one revision back is still broken. Read the history and pick a
revision you know was good.

**Common mistake.** Rolling back without checking whether a database migration
ran. If the new version migrated the schema and the old version can't read it,
rolling back the app alone makes things worse.

---

### 22. Your rollout is stuck. Diagnose it.

**Answer.** `kubectl rollout status` will eventually fail at
`progressDeadlineSeconds`; I don't wait for that. `kubectl get pods` shows what
the new ReplicaSet's pods are doing — `Pending` (no capacity), `ImagePullBackOff`
(registry), `CrashLoopBackOff` (app), or `Running 0/1` (readiness).

`kubectl get rs` showing two ReplicaSets with `DESIRED > 0` confirms it's stuck
mid-rollout — which means you have a **mixed fleet** serving right now, and
that's often the real user-facing symptom.

**Commands.**
```bash
kubectl rollout status deployment/orders-api -n orders --timeout=60s
kubectl get rs -n orders -o wide
kubectl describe pod NEW_POD -n orders | tail -20
```

**Follow-up:** *"Why `progressDeadlineSeconds`?"* → Without it, `rollout status`
blocks indefinitely and your pipeline hangs rather than failing. Failing fast is
what lets `--atomic` roll back.

**Common mistake.** Deleting the new pods to "retry". The ReplicaSet just
recreates them into the same failure.

---

### 23. Why does `helm upgrade` return 0 on a deployment that never came up?

**Answer.** Because by default Helm only asserts that the API server **accepted**
the manifests. It doesn't watch pods.

`--wait` makes it block until the resources are Ready. `--atomic` adds automatic
rollback if that wait fails. Without both, a green pipeline means "the YAML was
syntactically valid and RBAC allowed it" — which is not what anyone reading the
green tick believes it means.

**Follow-up:** *"What's the risk of `--atomic`?"* → It needs a longer timeout
than you think, and if the rollback itself fails you're in a worse state than
before. It also masks the failure — you should still read the logs to find out
*why* it rolled back, rather than treating a self-healed deploy as a non-event.

**Common mistake.** Assuming exit 0 means running. This is the same class of
error as question 19.

---

### 24. What does `revisionHistoryLimit` control, and what happens at 0?

**Answer.** How many old ReplicaSets are retained. Each one is a rollback target
— `kubectl rollout undo --to-revision` can't reach a ReplicaSet that's been
garbage collected.

At 0, old ReplicaSets are deleted immediately and **you cannot roll back with
kubectl at all**. Helm history would still exist, but the fast path is gone.

10 is the default and a sensible balance: enough history to matter, not enough to
clutter.

**Common mistake.** Setting it to 1 or 0 to "keep things tidy", then discovering
during an incident that there's nothing to undo to.

---

### 25. How do you deploy a config change so pods actually pick it up?

**Answer.** Editing a ConfigMap does **nothing** to running pods when it's
consumed via `env` or `envFrom` — those values are injected at container start
and never updated. The config appears to deploy successfully while every pod
keeps the old value, and every health signal stays green.

The fix is to change the **pod template**, which forces a rolling update. The
standard pattern is hashing the rendered ConfigMap into a pod annotation:

```yaml
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

Or `kubectl rollout restart` after the change.

**Follow-up:** *"What about volume-mounted ConfigMaps?"* → Those *do* update in
place, with kubelet sync lag of up to a minute — but the application still has to
re-read the file. Most don't.

**Common mistake.** `kubectl apply` on the ConfigMap and reporting the change as
deployed.

---

### 26. What's a canary deployment and how would you add one here?

**Answer.** Route a small fraction of production traffic to the new version,
watch real metrics, then promote or abort. It converts "we tested it in staging"
into "we tested it on 5% of real users with a fast exit".

The crude version is two Deployments behind one Service with a 19:1 replica
ratio, which gives you rough traffic splitting via endpoint count. The real
version needs a service mesh or Argo Rollouts, where you split by weight and
automate the analysis — promote if error rate and latency hold, roll back
automatically if not.

**Follow-up:** *"Why isn't it in this project?"* → It needs a mesh or Argo
Rollouts, which is a meaningful addition for one service. I'd call it out as the
honest next step rather than pretend it's covered. It's also the direct
prevention for the 30%-error incident in the failure lab.

**Common mistake.** Calling a blue/green switch a canary. Blue/green is
all-or-nothing; a canary is fractional.

---

### 27. Blue/green vs rolling update — trade-offs?

**Answer.** **Rolling** replaces pods incrementally. Cheap — no duplicate
infrastructure — but you run a mixed fleet during the rollout, and rollback means
another rolling update.

**Blue/green** stands up the full new environment alongside the old and switches
traffic atomically. No mixed fleet, and rollback is an instant switch back. Costs
double the resources during the transition, and any shared state — a database —
still has to be compatible with both.

For a stateless service where a mixed fleet is tolerable, rolling is right.
Where two versions genuinely can't coexist, blue/green is worth the cost.

**Common mistake.** Assuming blue/green makes rollback free. If the new version
migrated the database, the switch back doesn't help you.

---

### 28. How would you deploy a backward-incompatible database migration safely?

**Answer.** Expand/contract, across at least three releases.

**Expand** — add the new column/table, nullable, with no reads from it. Deploy.
Both old and new code work.
**Migrate** — backfill data, start dual-writing. Deploy.
**Contract** — only once every instance uses the new shape, drop the old column.

At every step, the previous version still runs, so rollback stays possible. The
alternative — one migration that breaks the old code — means the moment you
deploy, **you have no rollback path**, which is exactly when you most want one.

**Follow-up:** *"So what's the rollback plan during the migrate step?"* → Roll
back the application only; the schema tolerates both. That's the entire point of
the pattern.

**Common mistake.** Treating the migration as a deploy detail. It's the thing
that determines whether rollback exists at all.
---

## GKE specifics

### 29. Zonal vs regional GKE cluster — which and why?

**Answer.** A **regional** cluster replicates the control plane across three
zones *and* runs your node pool in each of them. So `node_count = 1` becomes
three VMs. That's the part people miss: regional triples your compute bill, not
just your control-plane availability.

Regional is correct for production — it survives a zone outage. **Zonal is
correct for a cost-controlled rehearsal**, and I'd say that explicitly rather
than pretend zonal is production-grade. The upgrade path is a cluster rebuild,
which is itself a useful exercise.

**Follow-up:** *"Does the cluster management fee differ?"* → No, both are
$0.10/hour. GKE's free tier gives **one** zonal or Autopilot cluster per billing
account a $74.40/month credit. A second cluster is billed in full — which is why
"just spin up a test cluster" doubles your bill.

**Common mistake.** Choosing regional for a lab and being surprised by three
nodes.

---

### 30. Standard vs Autopilot?

**Answer.** Autopilot manages nodes entirely — you pay per pod resource request,
Google handles node provisioning, upgrades, and security posture. For most teams
it's the better default: less to configure, less to get wrong.

Standard gives you node-level control: node service accounts, machine types,
Spot VMs, taints, DaemonSets, drains.

I chose Standard here **deliberately**, because the node-level concerns are the
thing worth demonstrating. On Autopilot, most of what this project teaches is
abstracted away.

**Follow-up:** *"When would Autopilot be wrong?"* → When you need DaemonSets with
privileged access, specific machine types, GPUs with custom drivers, or
node-level tuning. Autopilot also restricts some `securityContext` and hostPath
usage.

**Common mistake.** Presenting Standard as strictly better. It's a trade.

---

### 31. What is VPC-native, and what breaks if you get the ranges wrong?

**Answer.** VPC-native means pods get real VPC IPs via alias IP ranges, rather
than routes-based networking. It's required for Workload Identity, NEG-backed
load balancing, and Private Google Access to behave properly. Routes-based is
legacy.

It needs **two secondary ranges** on the subnet — one for pods, one for services.
The critical constraint: **secondary ranges cannot be resized in place while in
use.** Undersize them and you rebuild the cluster to grow.

Sizing: GKE allocates a /24 per node by default (110 pods max per node), so a /14
pod range supports about 1,024 nodes. IP space in a private range is free —
be generous.

**Follow-up:** *"Why does the firewall matter here?"* → Because dependency
firewall rules must be written against the **pod** CIDR, not the node CIDR. That
mistake produces connection timeouts that look exactly like application bugs, and
it's one of the top causes of failed cutovers.

**Common mistake.** Sizing the pod range from current pod count rather than
future node count.

---

### 32. Explain Workload Identity. Why is it better than a service-account key?

**Answer.** The Kubernetes ServiceAccount is bound to a Google service account.
When application code calls a Google API, the GKE metadata server mints a
short-lived token for that GSA. **No key material ever exists** — nothing to
commit to git, nothing to leak in a log, nothing to rotate.

A service-account JSON key, by contrast, never expires, works from any IP on
earth, and grants its roles to whoever holds the file. It's the most common root
cause of real GCP compromises.

The binding has **two halves and both are required**: an IAM policy on the GSA
granting `roles/iam.workloadIdentityUser` to
`serviceAccount:PROJECT.svc.id.goog[NAMESPACE/KSA]`, and the annotation
`iam.gke.io/gcp-service-account` on the KSA. The cluster also needs
`workload_identity_config` and the node pool needs `GKE_METADATA`.

**Follow-up:** *"A pod gets 403 from Secret Manager. Debug it."* → Check both
halves match exactly — namespace and KSA name, character for character. Then
confirm from inside the pod which identity it actually has:
```bash
kubectl exec POD -- curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email"
```
The 403 message names neither side of the mismatch, which is what makes it
annoying.

**Common mistake.** Configuring one half and assuming it's done.

---

### 33. What's wrong with the default GKE node service account?

**Answer.** GKE defaults to the **Compute Engine default service account**, which
holds `roles/editor` across the entire project. Any pod that escapes its
container — or simply reads the node metadata endpoint — inherits project-wide
write access.

Replacing it with a purpose-built SA is the highest-value, lowest-effort GKE
hardening step there is. The documented minimum is four roles: `logging.logWriter`,
`monitoring.metricWriter`, `monitoring.viewer`, and
`stackdriver.resourceMetadata.writer`.

Artifact Registry read should be granted **on the repository**, not at project
level — so nodes can pull this image, not every image in the project.

**Commands.**
```bash
gcloud container clusters describe CLUSTER --zone ZONE --format='value(nodeConfig.serviceAccount)'
```
If that says `default`, you've found something.

**Follow-up:** *"What else protects the metadata endpoint?"* →
`disable-legacy-endpoints=true` and `GKE_METADATA` mode, which block pods from
reading the v1beta1 metadata API and stealing the node SA's token.

---

### 34. Private nodes vs private endpoint. What's the difference?

**Answer.** **Private nodes** means nodes have no external IP. **Private
endpoint** means the *control plane* API is not reachable from the internet.

They're independent, and the useful combination is private nodes with a public
(but restricted) endpoint: nodes are unreachable from outside, and you can still
run `kubectl` from a laptop without a bastion.

Fully private endpoint requires a bastion, VPN or Interconnect — correct for
production, disproportionate for a lab.

**Follow-up:** *"With no external IP, how do nodes pull images?"* → **Private
Google Access** on the subnet, which routes Google API traffic over Google's
internal network. That's why this project needs no Cloud NAT — a security
improvement that also saves about $32/month.

**Common mistake.** Enabling private nodes without Private Google Access or NAT,
then debugging ImagePullBackOff for an hour.

---

### 35. What are `master_authorized_networks` and why do they matter?

**Answer.** A CIDR allowlist for who may reach the Kubernetes API endpoint.
Leaving it empty means the control plane accepts connections from the entire
internet — still authenticated, but exposed to credential stuffing and CVE
scanning.

It's free and takes one line. The reason it gets skipped is that the default
works, so nothing prompts you.

```hcl
authorized_networks = [
  { cidr_block = "203.0.113.42/32", display_name = "office" }
]
```

**Follow-up:** *"What breaks when you enable it?"* → CI, if it runs from
GitHub-hosted runners with rotating IPs. Options: self-hosted runners in the VPC,
Connect Gateway, or accepting a broader range. Worth knowing before you enable it
mid-pipeline.

---

### 36. What are Spot VMs and when shouldn't you use them?

**Answer.** 60–91% cheaper Compute Engine instances that Google may reclaim with
**30 seconds' notice**. Correct for stateless, replicated, interruption-tolerant
workloads, and for learning clusters.

Wrong for anything stateful, anything with a long startup, or a single-replica
service. If losing one node means an outage, you can't use Spot.

The useful side effect: Spot *forces* you to build for a node vanishing. In this
project that's why `minReplicas: 2`, a PDB, and topology spread exist — they're
load-bearing, not decoration.

**Follow-up:** *"How do you handle preemption gracefully?"* → GKE cordons and
drains on the preemption signal, so a PDB plus a proper `preStop` and graceful
shutdown mean it's a non-event. Mixed node pools — Spot for bulk, on-demand for a
baseline — hedge the risk.

---

### 37. How do GKE cluster upgrades work, and what breaks them?

**Answer.** Control plane first, then node pools — Kubernetes supports a control
plane up to two minor versions *ahead* of its nodes, never behind. Release
channels (RAPID/REGULAR/STABLE) let Google manage the cadence; REGULAR is the
sane default.

A node upgrade **drains each node in turn**. So the things that break it are the
things that block eviction: a PodDisruptionBudget with `ALLOWED DISRUPTIONS: 0`,
unmanaged bare pods, and pods with local storage.

`maxSurge: 1, maxUnavailable: 0` on the node pool adds a node before removing
one, so capacity never drops.

**Follow-up:** *"How do you test this before it matters?"* → Drain a node
manually as part of migration validation. It costs ten minutes and catches an
over-strict PDB before it stalls an upgrade at 02:00.

---

### 38. Cluster Autoscaler — when does it refuse to remove a node?

**Answer.** It scales up when pods are `Pending` for lack of resources, and down
when a node has been under ~50% utilised for about ten minutes *and* its pods can
be rescheduled.

It **refuses** to remove a node when: a pod has no controller (a bare pod), a PDB
would be violated, a pod uses local storage, a pod has restrictive affinity, or a
pod carries `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`.

Worth stating: an over-strict PDB doesn't just block upgrades, it **quietly costs
you money** by preventing scale-down.

**Follow-up:** *"How fast is scale-up?"* → 1–3 minutes: provision the VM, join
the cluster, pull the image. If your traffic spike is faster than that, HPA plus
CA won't save you — you need headroom, pause pods, or pre-scaling ahead of a
known event.

---

### 39. Why must Artifact Registry be in the same region as the cluster?

**Answer.** Pulls from a registry in the same region are free. Cross-region pulls
are billed as inter-region egress — a silent, recurring charge that scales with
how often pods restart.

It's also a latency issue on cold starts, but cost is the argument that lands.

This project forces `location = var.region` in Terraform so the mistake can't be
made.

**Follow-up:** *"Why Artifact Registry rather than Container Registry?"* →
`gcr.io` is deprecated. Artifact Registry additionally supports **immutable
tags**, per-repository IAM, and cleanup policies — the first of which eliminates
an entire class of deployment bugs.

---

### 40. How do you reduce GKE cost without breaking anything?

**Answer.** In rough order of impact per unit of risk:

1. **Zonal, not regional** — avoids 3× node cost.
2. **Spot VMs** — 60–91% off compute.
3. **Right-size requests** from measured usage. Over-requesting wastes capacity
   invisibly, because scheduling works on requests, not usage.
4. **No Cloud NAT** — use Private Google Access. ~$32/month.
5. **No Ingress unless you need one** — a forwarding rule is ~$18/month billed at
   zero traffic. `kubectl port-forward` validates for free.
6. **Cleanup policies on the registry**, so CI doesn't accumulate layers forever.
7. **Scale the node pool to zero overnight** — node cost stops, cluster fee
   continues.
8. **Delete the cluster when not in use.** Terraform makes recreation a
   five-minute operation.

**The meta-point:** set a **budget alert before creating anything**, and know
that a budget *alerts* — it does not cap. Nothing in GCP hard-stops billing by
default.

**Common mistake.** Optimising machine type while leaving an orphaned load
balancer and a detached persistent disk billing in the background.
---

## GCP, IAM, security

### 41. Explain Workload Identity Federation for GitHub Actions.

**Answer.** GitHub mints a short-lived OIDC token describing the exact repository,
ref, workflow and actor. GCP's Workload Identity Pool Provider validates it
against the GitHub issuer, checks an **attribute condition**, and exchanges it via
STS for a ~1-hour access token that impersonates a CI service account.

The alternative — a service-account JSON key in a GitHub secret — gives GitHub a
credential that never expires and works from anywhere.

**The critical line is the attribute condition:**
```hcl
attribute_condition = "assertion.repository == 'owner/repo'"
```
Without it, **any GitHub repository on the internet** — including one an attacker
creates in thirty seconds — can mint a token your provider accepts. It's the most
commonly misconfigured part of WIF, and it converts "keyless and secure" into
"publicly writable".

The job also needs `permissions: id-token: write`, or auth fails with a
confusingly generic credentials error.

**Follow-up:** *"Are `GCP_WIF_PROVIDER` and the SA email secrets?"* → Neither is
a credential — one is a resource path, one is an email. Storing them as secrets
just keeps the project ID out of a public repo.

---

### 42. What IAM roles should a CI pipeline have?

**Answer.** Enough to deploy, and not enough to destroy.

`roles/container.developer` lets it manage workloads but **not** create, modify
or delete clusters — a pipeline should never be able to delete the cluster it
deploys to. `roles/artifactregistry.writer` granted **on the specific
repository**, not at project level. `roles/iam.serviceAccountTokenCreator` if it
needs to impersonate.

Explicitly not: `roles/editor`, `roles/owner`, or `container.admin`.

**Follow-up:** *"How do you audit what an identity can actually do?"*
```bash
gcloud projects get-iam-policy PROJECT \
  --flatten="bindings[].members" --filter="bindings.members:SA_EMAIL" \
  --format="value(bindings.role)"
```

**Common mistake.** Granting project-level `artifactregistry.writer` because it's
one line shorter than a per-repository binding.

---

### 43. How would you manage secrets for a GKE workload?

**Answer.** Three tiers.

A **Kubernetes Secret** is base64 — encoding, not encryption. Anyone with `get
secret` RBAC reads it in plaintext, and it sits in etcd. It's an acceptable
baseline, not a good answer.

**Secret Manager with the CSI driver or External Secrets Operator** is the
correct answer: the value never becomes a Kubernetes Secret at all, it's
projected into the pod at runtime, authenticated by **Workload Identity**, and
rotates centrally with a full audit log.

The worst option is a chart-managed Secret from a values file — the value ends up
in your values file, your shell history if you used `--set`, and in the Helm
release, recoverable via `helm get values` for **every historical revision**.

**Follow-up:** *"How do you rotate one without downtime?"* → Create the new
credential first so both work, add the new Secret Manager version, then
`kubectl rollout restart` — because env vars are read at container start and a
Secret change alone does nothing to running pods.

---

### 44. What does `securityContext` do, and which settings matter most?

**Answer.** In order of value:

**`runAsNonRoot` / `runAsUser`** — a container escape then inherits an
unprivileged user, not root. The UID must match the one created in the
Dockerfile; if they drift, the container starts as a user that can't read its own
files.

**`allowPrivilegeEscalation: false`** — blocks setuid binaries gaining more
privilege than the parent.

**`readOnlyRootFilesystem: true`** — an attacker can't drop a binary or modify
code in place. Usually needs an `emptyDir` at `/tmp`, since many libraries assume
it's writable.

**`capabilities.drop: [ALL]`** — a web server needs none of the 14 default Linux
capabilities.

**`seccompProfile: RuntimeDefault`** — blocks ~300 rarely-needed syscalls.

**Follow-up:** *"How do you enforce this across a cluster?"* → Pod Security
Admission at `restricted`, or a policy engine — Gatekeeper or Kyverno — so it's
rejected at admission rather than depending on every team remembering.

---

### 45. Why are resource limits a security control, not just a cost control?

**Answer.** Because without them, one workload can consume a node's entire CPU
and memory and starve everything else on it — including system pods. That's a
denial of service, whether it's caused by a bug, a traffic spike, or something
deliberate.

Memory in particular: an unbounded container triggers node-level memory pressure,
which evicts *other* pods. One team's leak becomes everyone's outage.

It's also why `requests.memory == limits.memory` (Guaranteed QoS) matters for
anything you care about — it's last to be evicted.

**Common mistake.** Filing limits purely under FinOps.

---

### 46. What's in a public repository that shouldn't be?

**Answer.** The obvious: private keys, `.pem`/`.p12`, service-account JSON,
`.env`, tokens, passwords.

The less obvious, and more commonly missed: **`terraform.tfstate`** — state files
contain full resource attributes and can hold secrets in plaintext. Kubeconfig
files. Real project IDs, billing account IDs, internal hostnames and IP ranges.
Employee names and emails.

And critically: **git history**. A secret removed in a later commit is still in
history and still scraped.

**Commands.**
```bash
docker run --rm -v "$(pwd):/repo" zricethezav/gitleaks:latest detect --source=/repo
git ls-files | grep -E '\.(pem|key|p12)$|service-account.*\.json$|^\.env$'
git log -p --all | grep -E 'BEGIN [A-Z ]*PRIVATE KEY|"private_key"|AIza[0-9A-Za-z_-]{35}'
```

**Follow-up:** *"You committed a key. What's the first step?"* → **Rotate it.
Immediately.** Rewriting history is second. Public repos are scraped within
minutes; forks and caches keep copies you can't delete. Deleting the commit does
not un-leak it.

---

### 47. What is Binary Authorization and why would you want it?

**Answer.** A GKE admission control that refuses to run images that don't meet a
policy — typically, that they're signed by a trusted attestor and came from an
approved registry.

It closes the gap between "we scanned the image in CI" and "this specific image
is what's running". Without it, anyone with deploy permission can run an
arbitrary image from anywhere.

I'd pair it with cosign/Sigstore signing in the pipeline.

**Follow-up:** *"Why isn't it in this project?"* → Scope. But I'd name it as a
real gap rather than imply provenance is verified — the honest statement is
"we verify what we built, we don't verify what runs was built by us".

---

### 48. Someone asks for `roles/owner` to debug an issue. What do you say?

**Answer.** No, and then solve their actual problem.

I'd ask what specifically failed and grant the narrow role that covers it —
usually `roles/container.viewer` plus `roles/logging.viewer` is enough to debug,
and `kubectl auth can-i --list` tells them what they currently have.

If they genuinely need write access, time-bound it: a conditional IAM binding
with an expiry, or a break-glass account with alerting on its use.

**The reasoning I'd give them:** `owner` includes the ability to modify IAM,
which means the grant can't be audited or revoked reliably afterwards.

**Common mistake.** Granting it "temporarily". Temporary IAM grants are
permanent unless something expires them automatically.

---

### 49. What's the blast radius of a leaked node service account token?

**Answer.** Exactly the roles that SA holds — which is the whole point of
replacing the Compute Engine default. With the default, it's project-wide Editor:
read every bucket, modify every resource, escalate further.

With a purpose-built node SA holding four narrow roles, a leaked token can write
logs and metrics. Annoying, not catastrophic.

Getting the token is not exotic: any pod on the node can query the metadata
endpoint unless `disable-legacy-endpoints` and `GKE_METADATA` are set.

**Follow-up:** *"How would you detect it being used?"* → Cloud Audit Logs, alerting
on the node SA calling APIs it shouldn't, or being used from outside the expected
network.

---

### 50. How does GKE handle secrets at rest, and is that enough?

**Answer.** Secrets are stored in etcd, encrypted at rest by Google-managed keys
by default. **Application-layer secrets encryption** with a Cloud KMS key adds
envelope encryption so a raw etcd dump isn't readable without KMS access.

Neither addresses the real exposure: **anyone with `get secret` RBAC in that
namespace reads the plaintext value through the API.** Encryption at rest doesn't
help against an over-broad RBAC binding.

Which is the argument for Secret Manager: the value never becomes a Kubernetes
object, so Kubernetes RBAC isn't the thing standing between an attacker and the
credential.

---

### 51. A pod needs to call a Google API. Walk me through setting that up with no keys.

**Answer.** Five steps:

1. Create a Google service account for the workload.
2. Grant it the specific role it needs — nothing broader.
3. Bind the KSA to it:
   ```bash
   gcloud iam service-accounts add-iam-policy-binding GSA \
     --role roles/iam.workloadIdentityUser \
     --member "serviceAccount:PROJECT.svc.id.goog[NAMESPACE/KSA]"
   ```
4. Annotate the KSA:
   ```bash
   kubectl annotate sa KSA -n NAMESPACE iam.gke.io/gcp-service-account=GSA
   ```
5. Confirm the cluster has `workload_identity_config` and the node pool has
   `GKE_METADATA`.

Then the Google client libraries pick it up through Application Default
Credentials with no code change.

**Follow-up:** *"How do you verify it worked before the app needs it?"* → From
inside the pod, query the metadata server for the identity it actually has. If it
returns the *node* SA rather than the workload SA, the binding isn't taking
effect.

---

### 52. What would you check first in a GCP security review of a GKE cluster?

**Answer.** In order, because this order finds the most severe things fastest:

1. **The node service account** — is it the Compute Engine default? That's
   project-wide Editor on every node.
2. **User-managed service account keys** — `gcloud iam service-accounts keys
   list`. Any that exist are long-lived credentials.
3. **Master authorized networks** — empty means the API endpoint is
   internet-reachable.
4. **Workload Identity** — enabled, or are pods carrying mounted keys?
5. **Pod security** — anything running as root or privileged.
6. **Resource limits** — any container without a memory limit.
7. **Public IPs** on nodes.
8. **IAM bindings** for `roles/owner` and `roles/editor` on humans and services.

**Commands.**
```bash
gcloud container clusters describe CLUSTER --zone ZONE --format='value(nodeConfig.serviceAccount)'
gcloud iam service-accounts keys list --iam-account=SA_EMAIL
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.securityContext.runAsUser}{"\n"}{end}' | grep -c '^0$'
```

---

## Terraform & IaC

### 53. What's in a Terraform state file, and why does it matter?

**Answer.** The mapping between your configuration and real resource IDs, plus a
full snapshot of every resource attribute — **including values marked sensitive,
in plaintext**. Database passwords, generated keys, certificate contents.

Consequences: never commit it, always encrypt the backend, restrict access to it
as you would production credentials, and enable versioning so a corrupt state can
be recovered.

**Follow-up:** *"Local state vs remote — when is local acceptable?"* → A
single-operator lab, where losing state means recreating a disposable cluster.
The moment two people or a pipeline touch it, you need a remote backend with
**locking**, or two concurrent applies will corrupt it.

**Common mistake.** Marking a variable `sensitive` and assuming that protects the
state file. It only hides it from CLI output.

---

### 54. `terraform plan` shows a resource being destroyed and recreated. What do you do?

**Answer.** Stop and find out which attribute forced it — the plan says
`# forces replacement` next to the field.

Then decide whether replacement is acceptable. For a node pool, yes. For a
cluster, that's an outage. For a database, that's data loss.

If the change is unavoidable but the replacement isn't, the options are
`create_before_destroy`, a manual migration, or `terraform state mv` / an import
if the resource is being replaced only because of a refactor rather than a real
change.

**Follow-up:** *"How do you prevent an accidental one?"* → `prevent_destroy` in a
lifecycle block on anything irreplaceable, and `deletion_protection` on the GKE
cluster in real production. This project sets it `false` *deliberately*, because
the goal is that you can always tear everything down — and I'd say so rather than
present it as a best practice.

---

### 55. Why does the GKE module create a cluster with `remove_default_node_pool`?

**Answer.** Because Terraform can't manage the inline node pool that
`google_container_cluster` creates without recreating the cluster on every
change. Standard practice is to create the cluster with a throwaway default pool,
delete it immediately, and manage real pools as separate
`google_container_node_pool` resources.

The practical benefit: node pools can then be replaced without touching the
cluster — which is exactly the operation you perform for a machine-type change or
a node upgrade. Create the new pool, cordon and drain the old, delete it.

---

### 56. How do you structure Terraform for multiple environments?

**Answer.** Modules for reusable components, one directory per environment as the
composition root, and variables for everything that differs.

I avoid workspaces for environments — they share a single configuration, so it's
too easy to apply dev's changes to prod, and the state layout is less obvious.
Separate directories with separate state make the blast radius explicit.

The rule I'd state: **environments differ by variable values, not by
configuration.** The moment dev's `main.tf` diverges from prod's, dev stops being
a test of prod.

**Follow-up:** *"How do you avoid copy-paste between environments?"* → The
environment directory should be thin — module calls and variable values, nothing
else. If there's logic in it, it belongs in a module.

---

### 57. What's the difference between `count` and `for_each`?

**Answer.** `count` indexes by position; `for_each` keys by a string.

That matters on removal. With `count`, deleting the middle element shifts every
subsequent index, so Terraform destroys and recreates everything after it. With
`for_each`, each resource is keyed independently and removing one touches only
that one.

Use `count` for a simple on/off toggle (`count = var.enabled ? 1 : 0`), and
`for_each` for a collection of named things — which is why the IAM module uses
`for_each = toset(local.node_roles)`.

---

### 58. How do you handle a resource that already exists outside Terraform?

**Answer.** `terraform import` it into state, or use a `data` source if you only
need to reference it.

The import workflow: write the resource block first, `terraform import` it, then
`terraform plan` and iterate until the plan is empty. An empty plan is the proof
that your configuration matches reality.

Newer Terraform supports `import` blocks, which makes this reviewable in a PR
rather than a local command someone ran.

**Common mistake.** Importing and then applying without checking the plan —
which "fixes" the drift by destroying attributes you didn't describe.

---

### 59. What does `terraform validate` actually check?

**Answer.** Syntax, and configuration consistency against the **provider
schema** — resource types, attribute names, types, required fields. It does not
contact the cloud and needs no credentials, which is why it can run on a fork PR
with `-backend=false`.

It does not check whether resources can actually be created: quotas, permissions,
naming collisions, or valid-but-wrong values.

**Worth mentioning from experience:** on this project, `terraform validate`
caught a real error — `cleanup_policy` should be `cleanup_policies`, a
set-nested block. That's exactly the class of thing it exists for, and it's why
running it beats eyeballing the config.

---

### 60. How do you review a Terraform plan for a production change?

**Answer.** Read it for three things, in this order:

**Destroys.** Anything being destroyed or replaced — is that acceptable, and does
it cause an outage or data loss?

**Cost.** Which resources bill hourly? For GCP that's node pools, forwarding
rules, Cloud NAT gateways, persistent disks, and reserved IPs. A plan that adds a
forwarding rule adds ~$18/month you may not have intended.

**Blast radius.** Does this touch IAM, networking, or anything shared? Those have
consequences beyond the resource itself.

Then: does the plan match what the PR description claims? A plan with more
changes than the description is a red flag.

**Follow-up:** *"How do you make this reviewable?"* → Post the plan as a PR
comment automatically (this project's `terraform.yml` does), so review happens
before apply rather than in someone's terminal.

---

### 61. Why isn't `terraform apply` automatic on merge here?

**Answer.** Because this stack creates **billable** GKE resources, and auto-apply
on merge is how a learning project produces a surprise invoice. A human reads the
plan and dispatches the workflow.

More generally: auto-apply is defensible when the blast radius is well understood
and the plan is reviewed in the PR. It's indefensible when a bad merge can delete
a cluster. The middle ground — plan on PR, apply on manual dispatch with a
required reviewer on the GitHub environment — gets most of the automation benefit
with a human gate on the irreversible part.

---

### 62. What happens if two people run `terraform apply` at once?

**Answer.** With a locking backend (GCS, S3+DynamoDB), the second one blocks with
a lock error. Without locking — local state, or a backend without it — both write
state and you get corruption: resources created twice, or state that no longer
matches reality.

If a lock is stuck because a run was killed, `terraform force-unlock LOCK_ID` —
but only after confirming nothing is actually running, because force-unlocking a
live apply causes the corruption you were avoiding.

**Follow-up:** *"How do you recover corrupted state?"* → Restore from the
backend's version history, which is why versioning on the state bucket is
mandatory. Failing that, `terraform import` each resource back — slow and
error-prone, which is the argument for versioning.
---

## Docker, images, registry

### 63. Why a multi-stage build?

**Answer.** So compilers, build tools and package caches never reach the runtime
image. Smaller image, faster pulls, and — the part that matters — a much smaller
attack surface. A compiler in a production container is a tool for an attacker.

The secondary benefit is layer caching: copy `requirements.txt` and install
dependencies *before* copying source, so ordinary code commits rebuild in seconds
instead of re-resolving the dependency tree.

**Follow-up:** *"How else would you shrink an image?"* → A slim or distroless
base, `--no-cache-dir` on pip, combining RUN layers, and a `.dockerignore` that
excludes docs, tests, and `.git`. But the first question is always whether
something belongs in the runtime image at all.

---

### 64. Why does the exec form of CMD matter?

**Answer.** With the exec form (`CMD ["uvicorn", ...]`), your process becomes PID
1 and receives SIGTERM directly. With the shell form (`CMD uvicorn ...`), `sh`
becomes PID 1, and `sh` does not forward signals to its child.

So the application never receives SIGTERM, never drains, and **every rolling
update ends in a 30-second SIGKILL** — which users experience as dropped requests
on every deploy.

**Follow-up:** *"When would you want an init process like tini?"* → When the
container spawns child processes that could be orphaned, since PID 1 has special
responsibility for reaping zombies. For a single-process web server, the exec form
is enough.

---

### 65. How do you make a container image's version verifiable at runtime?

**Answer.** Bake the identity in at **build time** via `--build-arg`, promote it
to `ENV`, and expose it through an endpoint.

```dockerfile
ARG APP_VERSION
ARG GIT_COMMIT
ENV APP_VERSION=${APP_VERSION} GIT_COMMIT=${GIT_COMMIT}
```

Then `/version` returns the version, commit, branch and build timestamp. That's
what makes a running container traceable to an exact commit.

Two details that matter: declare the ARGs **after** the heavy layers, so changing
a commit SHA doesn't invalidate the dependency cache. And **assert it worked**
immediately after building — `docker inspect` the baked-in value and fail the
build if it doesn't match. That catches a broken ARG/ENV chain in seconds rather
than during a production version check.

Also add OCI labels (`org.opencontainers.image.revision`) so the image is
self-describing before you even run it.

---

### 66. Why is `:latest` a problem?

**Answer.** It's a mutable pointer, not a version. Three consequences:

**Non-deterministic deploys** — two pods created ten minutes apart can run
different code with an identical spec.

**Rollback is impossible** — there's no previous tag to roll back *to*.

**Verification is impossible** — you can't confirm what's running, because the
tag doesn't identify anything.

It also interacts badly with `imagePullPolicy`: with `IfNotPresent`, a node reuses
whatever it cached under that tag and never contacts the registry.

This project makes it a hard failure — the Helm chart refuses to render, and both
`build.sh` and `deploy.sh` reject it.

---

### 67. What are immutable tags and why do they matter?

**Answer.** An Artifact Registry setting: once `:2.4.17` points at a digest, it
can **never** be repointed. Pushing that tag again fails.

It eliminates the entire class of "the pipeline said SUCCESS but the old code is
running" caused by an overwritten tag — a re-run, a manual `docker tag`, a race
in CI. A tag becomes a version rather than a pointer.

It's also what makes `imagePullPolicy: IfNotPresent` safe. With mutable tags you'd
need `Always`, and pay a registry round-trip on every pod start.

---

### 68. Tag or digest — what should production deploy?

**Answer.** **Digest.** `repository@sha256:...` is byte-for-byte deterministic;
there's nothing left to be ambiguous about.

The workflow: build and push by tag (humans need readable names), resolve the
digest, then deploy by digest. This project's pipeline does exactly that —
`gcloud artifacts docker images describe` returns the digest, and Helm renders
`image@sha256:...`.

Immutable tags plus digest pinning is belt and braces, and both are free.

---

### 69. How do you keep a container image secure over time?

**Answer.** An image that was clean at build time isn't clean six months later —
new CVEs are published against the same bytes.

So: pin dependencies for reproducibility, scan the image in CI (Trivy), scan
dependencies (`pip-audit`), rebuild on a schedule so base-image patches land, and
rebuild on base-image updates.

**On gate thresholds** — this project fails on CRITICAL and only warns on HIGH.
The reason is practical: base images routinely carry HIGH findings with no
available fix. A gate that blocks every release for something unfixable gets
disabled within a month, and then you have no gate at all. Fail on what's
actionable.

**Follow-up:** *"What about `ignore-unfixed`?"* → Same argument. Alerting on a
vulnerability with no patch produces noise, not action — though you should still
track it for when a fix appears.

---

### 70. Why non-root, and what breaks when you switch?

**Answer.** A container escape then lands as an unprivileged user rather than
root. It's the single highest-value container hardening step.

What breaks: binding ports below 1024 (use 8080, not 80 — the Service maps it);
writing to paths owned by root; and images that assume a writable home directory.

The subtle one: **the UID in the Dockerfile and the `runAsUser` in the
securityContext must match.** If they drift, the container starts as a user that
can't read its own application files — a confusing failure that looks like a
missing file.

And with `readOnlyRootFilesystem: true` you usually need an `emptyDir` at `/tmp`,
because many libraries assume it exists and is writable.

---

### 71. What's a `.dockerignore` for, and what should be in it?

**Answer.** It excludes files from the build context. Two reasons: speed — a
`.git` directory or `node_modules` can be hundreds of megabytes uploaded to the
daemon on every build — and **security**, because anything in the context can end
up in the image via a careless `COPY .`.

At minimum: `.git`, `.env`, `*.tfstate`, `**/__pycache__`, test caches, docs, and
any credential-shaped file.

**Common mistake.** `COPY . .` with no `.dockerignore`, which has put `.env`
files and SSH keys into published images more than once.

---

## CI/CD & GitHub Actions

### 72. Design a pipeline for a containerised service on GKE.

**Answer.**

```
lint → unit tests → SAST → build → assert build identity → image scan
  → OIDC auth → push → resolve digest
  → helm upgrade --wait --atomic --set image.digest=…
  → rollout status → VERIFY VERSION → smoke test → post-deploy validation
```

The two things that distinguish this from a tutorial pipeline:

**The version-verification gate.** Without it, SUCCESS means the pipeline ran,
not that the right code is serving.

**A smoke test with a meaningful sample size.** Twenty requests against a
business endpoint, not one against `/health`. One request against a 30% failure
rate passes 70% of the time — that's a real detection gap and it's how a bad
release gets through a green pipeline.

**Follow-up:** *"What's the fastest useful thing to add to a bad pipeline?"* →
`--wait --atomic` on the Helm step. It's two flags and it converts "the deploy
reported success" into "the pods are actually running, or we rolled back".

---

### 73. What does `concurrency` do in a GitHub Actions workflow, and how would you set it?

**Answer.** It groups runs so a new one can cancel or queue behind an existing
one.

For **build/test** on a branch: `cancel-in-progress: true`. Saves CI minutes and
stops an old commit's job finishing after a newer one.

For **deploy**: `cancel-in-progress: false`, always. Cancelling mid-rollout leaves
the cluster in a half-updated state that nobody has a mental model of — some pods
new, some old, and Helm's record disagreeing with reality.

Same for `terraform apply`. Never interrupt an apply in flight.

---

### 74. How do you keep secrets out of a pipeline?

**Answer.** Ideally have none. OIDC/WIF for cloud auth removes the largest one.

For what remains: repository or environment secrets, never hard-coded; masked in
logs; never passed as command-line arguments (they appear in process listings and
sometimes in logs); and `gitleaks` on every push to catch what slipped in.

**Environment protection rules** are the underrated control — required reviewers
on the `prod` environment mean a compromised token still can't deploy without a
human.

**Follow-up:** *"How do secrets behave on fork PRs?"* → They're not available,
which is why this project's Terraform workflow runs `validate` (no credentials)
unconditionally and gates `plan` on the PR coming from the same repository.

---

### 75. What should fail a build, and what should only warn?

**Answer.** Fail on things that are **actionable and unambiguous**: failing tests,
lint errors, CRITICAL vulnerabilities with a fix available, a missing memory
limit, a `:latest` tag, a detected secret.

Warn on things you can't act on immediately: HIGH vulnerabilities with no
available fix, advisory-only dependency findings, style preferences.

**The principle:** a gate that fires on something nobody can fix gets disabled or
routed around, and then it protects nothing. Gate quality matters more than gate
quantity.

---

### 76. How would you deploy to production from CI without a long-lived credential?

**Answer.** OIDC federation, plus an environment with required reviewers.

The workflow requests an OIDC token (`permissions: id-token: write`), exchanges
it for a short-lived cloud token via WIF, and deploys. The GitHub environment
adds a human approval gate on the irreversible step.

The key configuration detail is the provider's **attribute condition**, pinning
which repository — and optionally which branch or tag — may assume the identity.
Without it, any repo can.

---

### 77. Your pipeline is green but the deploy didn't work. Where do you look?

**Answer.** At what each stage actually asserted.

Did the Helm step have `--wait`? Without it, it returned 0 when the API accepted
YAML. Did `rollout status` run, and did it have a timeout? Did the smoke test hit
a business endpoint or just `/health`? Did anything verify the *version*?

Then the specifics: the resolved digest in the push step versus what's running;
whether the pipeline authenticated to the right project; whether it pushed to the
registry the Deployment pulls from.

**The general principle:** a green pipeline reports on the pipeline. Making it
report on production requires deliberately adding checks that can fail for
production reasons.

---

### 78. How do you handle database migrations in a pipeline?

**Answer.** As a separate, ordered step — never inside the application's startup,
where N replicas would race.

Options: a Kubernetes Job run before the Deployment upgrade (a Helm pre-upgrade
hook does this cleanly), or a dedicated pipeline stage.

The hard requirement is **backward compatibility**, using expand/contract. If the
migration breaks the previous version, you've deployed something you cannot roll
back — which is the worst possible property for a release.

**Follow-up:** *"The migration succeeded and the deploy failed. Now what?"* →
That's precisely why the migration must be backward compatible: you roll the
application back and the schema tolerates it. If it isn't, you're now writing a
forward fix under pressure.

---

### 79. What's the difference between a self-hosted and a GitHub-hosted runner here?

**Answer.** GitHub-hosted runners are ephemeral and free for public repos, but
they come from rotating IP ranges — which conflicts with
`master_authorized_networks` on the cluster API.

Self-hosted runners inside the VPC solve that and can reach private endpoints,
but you now own their patching, isolation, and the risk that a compromised
workflow gets a foothold in your network. For public repositories, self-hosted
runners are genuinely dangerous — any fork PR could run code on them.

Middle ground: GKE **Connect Gateway**, which lets CI reach the cluster without
IP allowlisting.

---

### 80. How would you make a pipeline faster without weakening it?

**Answer.** Parallelise independent jobs — lint, test, Terraform validate, and
Helm lint have no dependency on each other. Cache dependencies and Docker layers
(`cache-from: type=gha`). Order Dockerfile layers so code changes don't
invalidate dependency installs. Use `concurrency` with `cancel-in-progress` on
branch builds.

What I would **not** cut: the version verification, the smoke test sample size,
or the image scan. Those are the checks that catch production problems, and
they're seconds, not minutes.

**The framing:** most slow pipelines are slow because of cache misses and serial
execution, not because of too many checks.

---

## Helm

### 81. `version` vs `appVersion` in Chart.yaml?

**Answer.** `version` is the **chart** version — bump it when templates change.
`appVersion` is the **application** version — bump it when the image changes.

They're independent, and conflating them costs you during an incident, because
"which chart shipped which app version" is only answerable if both were
maintained honestly. `helm list` shows both.

**The trap:** bumping `appVersion` alone changes what Helm *reports* and nothing
about what runs. No pod template changed, so no rollout happened. Every
human-readable signal says the new version; every pod serves the old one.

---

### 82. Why does the Deployment omit `replicas` when the HPA is enabled?

**Answer.** Because otherwise they fight. Helm sets replicas to 2 on every
upgrade; the HPA scales it back to 5. The visible symptom is a scale-down blip on
every deploy, and capacity dropping at exactly the moment you're deploying.

Omitting the field entirely when `autoscaling.enabled` lets the HPA own it. The
same problem appears with GitOps tools — Argo CD needs `ignoreDifferences` on
`spec.replicas`.

---

### 83. What does the `checksum/config` annotation do?

**Answer.** It hashes the rendered ConfigMap into the pod template annotation:

```yaml
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

Changing the ConfigMap changes the hash, which changes the pod template, which
triggers a rolling update.

Without it, a config change **deploys successfully and does nothing** — env vars
are injected at container start and never updated. That's a genuinely nasty class
of bug because every health signal stays green while behaviour is wrong.

---

### 84. `helm upgrade --reuse-values` vs `--reset-values`?

**Answer.** `--reuse-values` keeps the values from the previous release and layers
new `--set` flags on top. `--reset-values` discards them and re-renders purely
from the values files.

The trap with `--reuse-values` is accumulation: a `--set` from three deploys ago
is still in effect, invisibly. This project's failure-lab reset uses
`--reset-values` for exactly that reason — otherwise scenario 4's memory ballast
would still be set while you're trying to reproduce scenario 9.

**How to see what's actually applied:** `helm get values RELEASE` shows the
user-supplied overrides. Run it when a release behaves unexpectedly.

---

### 85. How do you debug a Helm template that renders wrong?

**Answer.** `helm template` to see the output without touching the cluster, and
`helm upgrade --dry-run --debug` to see it with the release context and computed
values.

For values specifically, `helm get values RELEASE` (overrides only) and
`helm get values RELEASE --all` (the merged result) — the difference between them
usually explains the surprise.

`helm lint` catches schema problems, and rendering to a file plus `kubeconform`
validates against the real Kubernetes schema.

**Follow-up:** *"An upgrade fails with 'field is immutable'."* → Something changed
in `spec.selector`, which cannot be modified after creation. That's why selector
labels must be **stable** and volatile labels like version and chart live in a
separate helper. The only fix is to delete and recreate the Deployment — an
outage.

---

### 86. How do you manage secrets in Helm?

**Answer.** Not in Helm, ideally.

A chart-managed Secret means the value lives in a values file, in your shell
history if you used `--set`, and in the Helm release Secret — recoverable via
`helm get values` for every historical revision. That's three copies you didn't
intend.

The options, in order: reference an existing Secret created out of band; or
better, Secret Manager with the CSI driver or External Secrets Operator, where the
value never becomes a Kubernetes object at all.

If you must template secrets, `helm-secrets` with SOPS at least keeps them
encrypted at rest in git.
---

## Monitoring, logging, alerting

### 87. What should you alert on?

**Answer.** **Symptoms users feel** — error rate, latency, availability. Not
causes: "CPU is high", "a pod restarted", "disk is 70% full".

A pod restarting at 03:00 that the system healed automatically is not worth
waking someone for. A 5xx rate of 3% is — even if every pod is Ready and every
CPU graph is flat.

The single most important alert in this project is on the **5xx rate**, because
it's the only one that catches a pod that returns 200 on `/health` and 500 on
every real request. Kubernetes considers that pod perfectly healthy: it stays in
the Service, keeps receiving traffic, and never restarts.

**Follow-up:** *"How do you stop alert fatigue?"* → Every alert must be
actionable and carry the first command to run. An alert that says "CPU is high"
and nothing else wastes the responder's first five minutes. If an alert fires and
the answer is ever "acknowledge and ignore", delete it — an alert nobody trusts is
worse than no alert.

---

### 88. Why alert at 85% of the memory limit rather than on OOMKilled?

**Answer.** Because alerting on an OOMKill tells you about an outage you already
failed to prevent. 85% gives you time to act.

Memory is **incompressible** — unlike CPU, which throttles, exceeding the limit
means the kernel kills the container instantly with no chance to log anything. So
there's no gradual degradation to notice; it's fine, then it's dead.

The same reasoning applies generally: alert on the leading indicator where one
exists.

---

### 89. Why alert on restart *rate* rather than restart count?

**Answer.** A cumulative count alerts forever after one historical restart. The
alert fires, someone acknowledges it, it fires again, and within two weeks it's
muted — at which point you have no restart alerting at all.

A rate (`increase(...[10m]) > 2`) fires when something is *currently* wrong and
resolves when it stops.

This generalises: alert on rates and deltas, not on monotonically increasing
counters.

---

### 90. Why p95 and p99 rather than average latency?

**Answer.** An average hides the tail. If 90% of requests take 10ms and 10% take
5 seconds, the average is ~510ms — which looks tolerable, while one user in ten is
having an awful experience.

Reading them together is diagnostic:
- p50 flat, p99 spiking → a *subset* of requests is pathological: a slow query, a
  cold cache, one bad pod.
- All three rising together → systemic: CPU throttling, a slow dependency,
  saturation.
- A step change at a deploy → the new version is slower.

Rising latency is often the early warning for a 5xx incident, because requests get
slower until upstream timeouts convert slowness into errors.

---

### 91. Why does structured logging matter?

**Answer.** Because it's the difference between `jsonPayload.status>=500` —
instant, precise, across the whole fleet — and grepping free text.

Cloud Logging parses each JSON key into an indexed field. Plain text
(`2026-08-26 ERROR something failed`) arrives as one opaque string; you can't
query it by status, version, or pod.

The fields worth including on every line: severity (use that exact name — Cloud
Logging maps it), a **request ID** for correlation, and the version, commit and
pod so you can answer "is this only happening on 2.4.17?" in one query.

**The query that earns its keep:**
```bash
kubectl logs -n orders -l app=orders-api --tail=1000 \
  | jq -r 'select(.status>=500) | .pod' | sort | uniq -c
```
One pod failing means restart it and check its node. All pods means a bad version
or a shared dependency. That's a fork in the entire investigation, answered in one
command.

---

### 92. What should you never log?

**Answer.** Passwords, tokens, API keys, full authorisation headers, payment
details, personal data, and full request bodies (which contain all of the above).

Logs are read by more people than you expect, retained for 30 days, exported to
other systems, and attached to tickets.

Also don't log **probe requests**. `/health` and `/ready` are hit every few
seconds per pod: pure ingestion cost, zero information, and Cloud Logging bills
per GiB past 50 free.

**Follow-up:** *"You find a token in production logs. What do you do?"* → Rotate
it first, then remove the log statement, then check whether the logs were exported
anywhere. Deleting the log entries is the least important step.

---

### 93. How would you alert on something with no built-in metric?

**Answer.** A **log-based metric**. Any Cloud Logging query can become a metric,
and any metric can become an alert.

```bash
gcloud logging metrics create orders_api_5xx \
  --log-filter='resource.type="k8s_container"
                resource.labels.namespace_name="orders"
                jsonPayload.status>=500'
```

This is also the cheap path to 5xx alerting **without** paying for Managed
Prometheus — the logs are already being ingested, so the metric is nearly free.

The same pattern covers Kubernetes events (scheduling failures, image pull
failures) which have no native metric but are exported to Cloud Logging.

---

## Migration

### 94. What's the first thing you do in a migration discovery phase?

**Answer.** Establish whether the workload is genuinely **stateless**. Local file
writes, in-memory sessions, singleton background jobs, or anything assuming one
instance — any of those turn a two-week migration into a six-month redesign.

Then the inventory: dependencies, ports, DNS, certificates and their expiry
dates, secrets, external APIs, firewall rules, and the current deployment and
rollback process.

**The three that most often break cutovers**, and I'd ask about them explicitly:

1. **Firewall rules written against the old VM subnet.** They must be rewritten
   against the **pod** CIDR, which is a different range. Missing this produces
   connection timeouts that look like application bugs.
2. **Third parties allowlisting your old egress IP.** Payments fail at cutover
   and nobody remembers why.
3. **DNS TTL.** At 3600 seconds, a DNS-based rollback takes an hour. Lower it 24
   hours ahead.

---

### 95. How would you sequence a low-risk cutover?

**Answer.** Staged, with the rollback path intact at every point.

Deploy to the new platform with **no** production traffic and validate against
the internal endpoint. Then mirrored or synthetic traffic to compare behaviour.
Then DNS-weighted 10%, watch 30 minutes. Then 50%, watch an hour. Then 100%.

**The old VMs stay running, serving nothing, for two weeks.** Rollback is a DNS
weight change. That's the cheapest insurance in the whole project, and
decommissioning early is how a month-end problem in week three becomes an
incident with no way back.

**Follow-up:** *"When do you abort?"* → Error rate above the old baseline, p95
more than 2× baseline, any data-integrity concern (immediately, no discussion), a
dependency unreachable and not fixable in 15 minutes, or the team simply not
confident. Rolling back a migration isn't a failure — it's the option you built
deliberately.

---

### 96. How do you prove the migration succeeded?

**Answer.** Against **pre-migration baselines**, which is why you record them
before you start: p50/p95/p99 latency, error rate, and requests per second at
peak.

Without them, "is it slower than before?" is unanswerable and every performance
discussion becomes opinion.

Then the checks at intervals — immediately, 1h, 24h, one week:

- Technical: pods healthy, zero restarts, correct version verified, error rate at
  or below baseline, latency within ~20%, logs flowing, no unexpected dependency
  errors.
- Resilience: HPA scaled up *and back down* under real load; a deploy performed
  and verified; **a rollback performed and verified** before you need it.
- **Business**: a human from the application team retrieving a real order end to
  end. HTTP 200 is not the same as correct.

The 24-hour mark matters because memory leaks and connection-pool exhaustion only
appear after real traffic.

---

### 97. What's your rollback plan for the migration itself?

**Answer.** Keep the old system running and revert DNS. That's it — and its
simplicity is the point.

For it to work: the DNS TTL must already be low (lowered 24h ahead), the old VMs
must still be capable of serving (not just powered on — health-check them), and
the data layer must be compatible with both, which usually means the old system
stays the source of truth until cutover is complete.

**The failure mode to name:** if the new system has been writing to a shared
database in a new schema, reverting DNS doesn't revert the data. That's why
schema changes go through expand/contract, and why the migration and the schema
change should not happen in the same window.

---

## Incident response & judgement

### 98. Version 2.4.17 was deployed. Users report intermittent 500s. The pipeline says SUCCESS. First move?

**Answer.** **Quantify before debugging.** "Users are getting errors" isn't
actionable; "28% of `/api/orders` requests have returned 500 since 13:52" is.

Three questions: what percentage, since when precisely, and which endpoints. One
endpoint means a code path; all endpoints means a dependency or infrastructure.

Then correlate: the deploy was 13:51, errors started 13:52. That's not proof —
check whether anything *else* changed at 13:51 — but it's a strong hypothesis.

Then check whether it's a **mixed fleet** rather than a bad version. If half the
pods are 2.4.16 and half are 2.4.17, "intermittent" means the rollout is stuck,
and the fix is different.

Then: **roll back.** Timebox investigation to about five minutes. If I don't have
a confident cause by then, I stop the user impact and investigate with no clock
running.

**Commands.**
```bash
./scripts/health-check.sh -n orders
helm history orders-api -n orders
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=1000 | jq -r 'select(.status>=500) | .pod' | sort | uniq -c
./scripts/rollback.sh -n orders
```

**Common mistake.** Reading application code first. You're an operator: your job
is to stop the bleeding and hand a reproducible failure to the people who own the
code.

---

### 99. When do you *not* roll back?

**Answer.** Four cases.

**The problem predates the deploy.** You'd revert an innocent release, lose time,
and still have the problem.

**The new version fixes something worse.** Rolling back reintroduces a more
severe bug.

**A database migration would break.** If 2.4.17 ran a migration 2.4.16 can't
read, rolling back the application without the schema makes it worse. This is the
one genuine trap, and it's why expand/contract matters.

**There's nothing to roll back to** — a first release, or `revisionHistoryLimit`
garbage-collected the target.

Otherwise, roll back. The asymmetry is stark: a rollback that turns out to be
unnecessary costs a few minutes; debugging in production while the error rate
climbs costs an SLO.

---

### 100. Something you built caused an outage. Walk me through it.

**Answer.** *(Structure it: situation, action, outcome, and — most importantly —
what changed afterwards.)*

A usable example from this project's own work:

> "I wrote the operations dashboard and it reported the HPA as configured
> `min 12%/70% max 2 current 4` — nonsense values. I'd parsed
> `kubectl get hpa --no-headers` positionally with awk, and TARGETS prints as
> `cpu: 12%/70%` — two whitespace-separated tokens. Every column after it shifted
> silently.
>
> It's a small bug, but the failure mode is the bad kind: **it didn't error, it
> lied.** During an incident I'd have been reading wrong numbers with full
> confidence.
>
> I found it by actually running the tool rather than assuming it worked, fixed it
> with `-o jsonpath`, and wrote the rule into CONTRIBUTING.md: never parse kubectl
> output positionally, because field values contain spaces."

**What interviewers are listening for:** that you own it without excessive
self-flagellation, that you understand *why* it happened rather than just what,
that the fix was systemic rather than a patch, and that you're honest about a
mistake at all. Candidates who claim they've never caused an incident are either
inexperienced or not being straight.

**Common mistake.** Choosing an example where someone else was at fault, or one
so trivial it reads as evasion.

---

## How to use this list

**Don't read it.** Cover the answer, say yours out loud, then compare. Speaking
an answer is a different skill from recognising one, and interviews test the
first.

**Prioritise these ten** if you're short on time — they carry the most weight for
a GKE support role:

| # | Question |
|---|---|
| 1 | CrashLoopBackOff — first five commands |
| 3 | The three probes, and why liveness must not check dependencies |
| 6 | Pods healthy, Service dead → check endpoints |
| 19 | Pipeline green, wrong version running |
| 21 | `helm rollback` vs `kubectl rollout undo` |
| 32 | Workload Identity, and its two required halves |
| 33 | The default node service account problem |
| 87 | Alert on symptoms, not causes |
| 98 | Intermittent 500s — quantify, then roll back |
| 100 | An outage you caused |

**Every answer here maps to something in this repository.** When you can point at
the code and say "here's where I did that, and here's the failure-lab scenario
that proves it", you're no longer answering from theory.

# kubectl Command Reference

Organised by **when you'd run it**, not alphabetically. Knowing that
`kubectl describe` exists is not the skill; knowing it's your second command
after `get pods` and your first for anything `Pending` — that's the skill.

---

## Before anything else — where am I?

```bash
kubectl config current-context        # RUN THIS BEFORE EVERY WRITE OPERATION
kubectl config get-contexts
kubectl config use-context CONTEXT
kubectl config set-context --current --namespace=orders   # stop typing -n
```

> **When:** every single time before a `delete`, `apply`, `scale`, or `rollout`.
> Deploying to the wrong cluster because your context was left pointing
> elsewhere is a genuinely common production incident. `deploy.sh` refuses to
> run a non-local deploy against a `kind-*` context for exactly this reason.

```bash
kubectl auth can-i create deployments -n orders
kubectl auth can-i --list -n orders
```
> **When:** a command returns `Forbidden` and you need to know whether it's you
> or the object. Also on day one in a new cluster, to learn your own permissions
> before you need them.

---

## "Is production healthy?"

```bash
kubectl get pods -n orders -o wide
kubectl get deploy,svc,hpa,pdb -n orders
kubectl get endpoints orders-api -n orders
kubectl top pods -n orders
kubectl top nodes
```

> **The four numbers that matter:** `READY` (n/n), `STATUS` (Running),
> `RESTARTS` (0), and endpoints (non-empty). Everything else is detail.

```bash
./scripts/health-check.sh -n orders      # all of the above, interpreted
./monitoring/ops-dashboard.sh -n orders  # the full dashboard, in a terminal
```

---

## "Check the pods"

```bash
kubectl get pods -n orders
kubectl get pods -n orders -o wide                          # + node and IP
kubectl get pods -n orders -w                               # watch a rollout live
kubectl get pods -n orders -L app.kubernetes.io/version     # version as a column
kubectl get pods -n orders --show-labels
kubectl get pods -A --field-selector=status.phase!=Running  # everything unhealthy, cluster-wide
kubectl get pods -n orders --sort-by=.status.containerStatuses[0].restartCount
```

> **`-L app.kubernetes.io/version`** is the fastest version check there is —
> one column, every pod, no port-forward.

```bash
kubectl describe pod POD -n orders
```
> **When:** always second, after `get pods`. **Always first** for anything
> `Pending` — there's no container, so there are no logs, and the answer is in
> the events at the bottom.

The four sections worth jumping straight to:
```bash
kubectl describe pod POD -n orders | grep -A6 "Last State"    # why it died
kubectl describe pod POD -n orders | grep -A8 "Events"        # what happened
kubectl describe pod POD -n orders | grep -A5 "Readiness"     # probe config
kubectl describe pod POD -n orders | grep -A4 "Limits"        # resources
```

---

## "Check the logs"

```bash
kubectl logs POD -n orders
kubectl logs -f POD -n orders                                    # follow
kubectl logs POD -n orders --previous                            # ← THE ONE
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=100
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --prefix --tail=100
kubectl logs POD -n orders --since=15m
kubectl logs POD -n orders --since-time=2026-08-26T13:50:00Z
kubectl logs POD -n orders -c CONTAINER                          # multi-container
kubectl logs POD -n orders --all-containers --timestamps
```

> **`--previous` is the crash-debugging command.** For a `CrashLoopBackOff`, the
> *current* container just started and hasn't failed yet — the reason it died is
> in the *previous* one. It holds only the **last** terminated container, so a
> second restart overwrites it. Capture it immediately.

Because this app logs structured JSON:
```bash
K="kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=1000"
$K | jq -c 'select(.status >= 500)'
$K | jq -r 'select(.status >= 500) | .pod' | sort | uniq -c   # ONE pod or ALL pods?
$K | jq -r '.version' | sort | uniq -c                        # mixed fleet?
$K | jq -c 'select(.request_id=="abc-123")'                   # one request, end to end
```

> **`select(.status>=500) | .pod | uniq -c`** is diagnostic gold: one pod failing
> means restart it and check its node; all pods failing means a bad version or a
> shared dependency.

---

## "What changed?"

```bash
kubectl get events -n orders --sort-by=.lastTimestamp
kubectl get events -n orders --field-selector type=Warning
kubectl get events -n orders --field-selector involvedObject.name=POD
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -30
```

> **When:** immediately after `get pods` shows something wrong. Events are
> Kubernetes explaining itself, and for scheduling, image pulls, probes and
> evictions the answer is *only* here.
>
> ⚠️ **Events expire after ~1 hour.** Capture them during the incident:
> `./scripts/collect-logs.sh -n orders`

---

## "Deploy version X" / "Check the rollout"

```bash
kubectl rollout status deployment/orders-api -n orders --timeout=5m
kubectl rollout history deployment/orders-api -n orders
kubectl rollout history deployment/orders-api -n orders --revision=7
kubectl rollout restart deployment/orders-api -n orders     # force new pods, same image
kubectl rollout pause deployment/orders-api -n orders       # freeze mid-rollout
kubectl rollout resume deployment/orders-api -n orders
```

> **`rollout status` is the command that catches a deploy that "succeeded" but
> never came up.** It blocks until the new ReplicaSet reaches its desired count,
> or fails at `progressDeadlineSeconds`.
>
> **`rollout restart`** is the correct way to force new pods without changing the
> image — after a Secret changes, for instance.

```bash
kubectl get rs -n orders -o wide     # more than one with DESIRED>0 = stuck rollout
```

---

## "Roll it back"

```bash
kubectl rollout undo deployment/orders-api -n orders
kubectl rollout undo deployment/orders-api -n orders --to-revision=7
```

> ⚠️ **This bypasses Helm.** The live Deployment changes; the Helm release does
> not. Helm now believes something different is deployed and the next
> `helm upgrade` will silently re-apply the bad version. Prefer
> `helm rollback`; use this only when Helm is unavailable, and reconcile after.

```bash
kubectl set image deployment/orders-api orders-api=IMAGE:2.4.16 -n orders   # break-glass
kubectl scale deployment/orders-api --replicas=5 -n orders                  # emergency capacity
```

→ [ROLLBACK_RUNBOOK.md](ROLLBACK_RUNBOOK.md)

---

## "What version is running?"

```bash
# Fastest: a label column
kubectl get pods -n orders -L app.kubernetes.io/version

# What the Deployment ASKS for
kubectl get deployment orders-api -n orders \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Requested vs ACTUALLY RUNNING — these can disagree
kubectl get pods -n orders -l app.kubernetes.io/instance=orders-api \
  -o custom-columns='POD:.metadata.name,SPEC:.spec.containers[0].image,RUNNING:.status.containerStatuses[0].imageID'

# The only ground truth
kubectl port-forward -n orders svc/orders-api 8080:80 &
for i in $(seq 1 10); do curl -s localhost:8080/version | jq -r .application_version; done | sort | uniq -c
```

> **`.spec.containers[0].image` vs `.status.containerStatuses[0].imageID`** —
> requested vs resolved. When a mutable tag has been overwritten, only `imageID`
> tells the truth. This distinction is the single most useful thing on this page.

```bash
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17
```
→ [docs/VERSION_VERIFICATION.md](docs/VERSION_VERIFICATION.md)

---

## "The service is down but the pods look fine"

```bash
kubectl get endpoints orders-api -n orders          # ← START HERE
kubectl get svc orders-api -n orders -o jsonpath='{.spec.selector}'
kubectl get pods -n orders --show-labels
kubectl describe svc orders-api -n orders
```

> **`get endpoints` collapses the whole problem to one line.** Empty means either
> the selector matches nothing, or no matching pod is Ready. Compare
> `svc.spec.selector` against pod labels to tell which.

```bash
kubectl port-forward -n orders svc/orders-api 8080:80    # test through the Service
kubectl port-forward -n orders POD 8080:8080             # test the pod directly
```
> **When:** if the pod works directly but the Service doesn't, it's routing —
> selector or `targetPort`. That comparison isolates it in 30 seconds.

```bash
kubectl run tmp --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://orders-api.orders.svc.cluster.local/health
```
> **When:** testing in-cluster DNS and connectivity from a pod's perspective.

---

## "Check the nodes"

```bash
kubectl get nodes
kubectl get nodes -o wide
kubectl describe node NODE
kubectl describe node NODE | grep -A10 Conditions          # MemoryPressure, DiskPressure
kubectl describe node NODE | grep -A8 "Allocated resources"  # REQUESTS vs capacity
kubectl top nodes
kubectl get pods -A -o wide --field-selector spec.nodeName=NODE
```

> **`Allocated resources` shows REQUESTS, not usage.** A cluster idling at 5%
> real CPU can be 100% requested and completely unschedulable. This is the
> single most misread output in Kubernetes.

```bash
kubectl cordon NODE                                          # no new pods
kubectl drain NODE --ignore-daemonsets --delete-emptydir-data # evict everything
kubectl uncordon NODE
```
> **When:** node maintenance, or removing a misbehaving node. If the drain
> **hangs**, check PodDisruptionBudgets — `ALLOWED DISRUPTIONS: 0` is the cause.

---

## "Is HPA working?"

```bash
kubectl get hpa -n orders
kubectl describe hpa orders-api -n orders      # read the CONDITIONS block
kubectl top pods -n orders
kubectl get deployment orders-api -n orders -o jsonpath='{.spec.template.spec.containers[0].resources}'
```

> **`TARGETS: <unknown>/70%`** — `kubectl top pods` splits the two causes in one
> command: if `top` fails, metrics-server is down; if `top` works,
> `requests.cpu` is unset and the HPA has no denominator.

→ [docs/AUTOSCALING.md](docs/AUTOSCALING.md)

---

## Config and secrets

```bash
kubectl get cm -n orders
kubectl get cm orders-api-config -n orders -o yaml
kubectl get secrets -n orders                              # names and types only
kubectl exec POD -n orders -- env | sort                   # what the container ACTUALLY sees
```

> **`kubectl exec ... env`** is the fastest way to settle "is the config
> applied?" — it shows what the process sees, not what you think you deployed.
>
> ⚠️ **Never** `kubectl get secret -o yaml` in a shared terminal or a recorded
> session. Base64 is encoding, not encryption.

```bash
kubectl create secret generic orders-api-secrets -n orders \
  --from-literal=ORDERS_DB_DSN='...'
kubectl rollout restart deployment/orders-api -n orders   # required: env is read at start
```

> **A ConfigMap or Secret change does NOT restart pods.** Values consumed via
> `env`/`envFrom` are injected at container start and never updated. This chart
> solves it with a `checksum/config` pod annotation; otherwise use
> `rollout restart`.

---

## Debugging inside a container

```bash
kubectl exec -it POD -n orders -- sh
kubectl exec POD -n orders -- ls -la /
kubectl exec POD -n orders -- cat /proc/1/status | grep -i uid
kubectl debug POD -n orders -it --image=busybox --target=orders-api   # ephemeral container
```

> **`kubectl debug`** is the answer for a distroless or read-only image where
> `exec` gives you nothing useful — it attaches a debug container sharing the
> pod's namespaces. This image is read-only-rootfs and non-root, so a plain
> `exec` can't install tools.

---

## Resource inspection

```bash
kubectl get deployment orders-api -n orders -o yaml
kubectl get deployment orders-api -n orders -o jsonpath='{.spec.template.spec.containers[0].resources}'
kubectl get all -n orders
kubectl api-resources                                  # what kinds exist here
kubectl explain deployment.spec.strategy.rollingUpdate # built-in field docs
kubectl diff -f manifest.yaml                          # what WOULD change
```

> **`kubectl explain`** is underused. It's offline API documentation for the
> exact cluster version you're on — more reliable than a web search that might
> describe a different version.
>
> **`kubectl diff`** before `apply`, always, on anything you care about.

---

## The commands to be careful with

```bash
kubectl delete pod POD -n orders                    # safe: the Deployment recreates it
kubectl delete deployment orders-api -n orders      # DESTRUCTIVE - deletes all pods
kubectl delete namespace orders                     # DESTRUCTIVE - deletes EVERYTHING in it
kubectl delete pod POD --grace-period=0 --force     # dangerous - see below
```

> **`--grace-period=0 --force`** removes the API object while the container may
> still be running on the node. For a StatefulSet that risks split-brain — two
> instances believing they own the same identity and volume. Investigate why a
> pod is stuck `Terminating` before reaching for it.
>
> **Deleting a namespace deletes everything in it**, including Secrets and PVCs.
> There is no undo.

---

## Useful output formats

```bash
-o wide                                    # extra columns
-o yaml / -o json                          # everything
-o jsonpath='{.spec.replicas}'             # one field
-o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[0].image'
--sort-by=.metadata.creationTimestamp
--no-headers                               # for scripting
-l key=value                               # label selector
--field-selector status.phase=Running
```

> ⚠️ **Don't parse `--no-headers` output positionally with `awk`.** Fields can
> contain spaces — `kubectl get hpa` prints TARGETS as `cpu: 12%/70%`, which is
> two tokens, silently shifting every column after it. Use `-o jsonpath` or
> `-o custom-columns` in scripts. (This exact bug appeared in this project's own
> dashboard and was caught by running it.)

---

## The 10 to know cold

```bash
kubectl config current-context                              # 1. where am I?
kubectl get pods -n NS -o wide                              # 2. what state?
kubectl describe pod POD -n NS                              # 3. why?
kubectl logs POD -n NS --previous                           # 4. why did it crash?
kubectl get events -n NS --sort-by=.lastTimestamp           # 5. what changed?
kubectl get endpoints SVC -n NS                             # 6. is traffic routed?
kubectl rollout status deployment/D -n NS                   # 7. did the deploy finish?
kubectl rollout undo deployment/D -n NS                     # 8. undo it
kubectl top pods -n NS                                      # 9. resource usage
kubectl get pods -n NS -L app.kubernetes.io/version         # 10. what version?
```

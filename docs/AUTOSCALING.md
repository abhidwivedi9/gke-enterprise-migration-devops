# Autoscaling

## Three different autoscalers

People say "autoscaling" and mean one of three things. Being precise about which
is the first step in every autoscaling conversation, and a common interview trap.

| | Scales | Trigger | Where configured |
|---|---|---|---|
| **HPA** — Horizontal Pod Autoscaler | Pod **count** | CPU / memory / custom metrics | `helm/application/templates/hpa.yaml` |
| **VPA** — Vertical Pod Autoscaler | Pod **size** (requests/limits) | Observed usage | Not used here |
| **CA** — Cluster Autoscaler | **Node** count | Pending pods | `terraform/modules/gke` |

They chain: HPA adds pods → pods go `Pending` if there's no capacity → CA adds a
node → pods schedule. **HPA and VPA conflict** on the same resource and should
not both manage CPU for the same workload.

---

## The configuration, and why each value is what it is

```yaml
autoscaling:
  enabled: true
  minReplicas: 2          # survives one node failure without a total outage
  maxReplicas: 5          # HARD CEILING on how much this workload can cost
  targetCPUUtilizationPercentage: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30    # react fast
      policies: [{type: Percent, value: 100, periodSeconds: 30}]
    scaleDown:
      stabilizationWindowSeconds: 300   # retreat slowly
      policies: [{type: Percent, value: 50, periodSeconds: 60}]
```

**`minReplicas: 2`** — one replica means every node drain is an outage.

**`maxReplicas: 5`** — this and the node pool's `max_node_count` are the two
numbers that bound your worst-case bill. A runaway HPA with no ceiling is a
self-inflicted denial-of-wallet.

**Asymmetric stabilisation windows** — scaling up late costs you an SLO; scaling
up early costs pennies. Scaling *down* too eagerly causes flapping, so it waits
5 minutes of sustained low load.

### The 70% is not what people assume

**`targetCPUUtilizationPercentage` is a percentage of the CPU *request*.** Not
the limit. Not the node.

```
requests.cpu = 50m
target       = 70%
             → the HPA aims to keep average usage near 35m per pod
```

The scaling formula:

```
desiredReplicas = ceil( currentReplicas × ( currentUtilization / targetUtilization ) )
```

Worked example:

```
2 replicas, each at 45m against a 50m request → 90% utilisation
desired = ceil( 2 × (90 / 70) ) = ceil(2.57) = 3
```

The HPA also applies a ±10% tolerance, so it won't churn on small deviations.

---

## Watching it work

```bash
kubectl get hpa -n orders
kubectl get hpa orders-api -n orders -w
kubectl describe hpa orders-api -n orders     # the "why" — read the Conditions
kubectl top pods -n orders
```

```
NAME         REFERENCE               TARGETS       MINPODS  MAXPODS  REPLICAS  AGE
orders-api   Deployment/orders-api   cpu: 6%/70%   2        4        2         57s
```

That's real output from this project's kind cluster. Note the progression when
the HPA first starts:

```
[1] orders-api   cpu: <unknown>/70%   2   4   1   26s
[2] orders-api   cpu: <unknown>/70%   2   4   2   43s
[3] orders-api   cpu: 6%/70%          2   4   2   57s
```

`<unknown>` for the first ~45 seconds is **normal** — metrics-server needs a
couple of scrape intervals before it can report. Don't diagnose an HPA within a
minute of creating it.

### Load test

```bash
./scripts/load-test.sh -n orders -d 180 -c 20
```

Watch: replicas climb within ~30–60s of sustained load, then hold for 5 minutes
after load stops before scaling back down. Both behaviours are the
`stabilizationWindowSeconds` values doing their job.

---

## Why an HPA isn't scaling

Work through these **in order**. The first two cover most cases.

### 1. `TARGETS: <unknown>/70%`

One command tells you which of the two causes it is:

```bash
kubectl top pods -n orders
```

**`top` fails** → metrics-server isn't running or isn't Ready.

```bash
kubectl get deployment metrics-server -n kube-system
kubectl logs -n kube-system deployment/metrics-server --tail=30
```

> On **kind** (and any cluster with self-signed kubelet certs), metrics-server
> needs `--kubelet-insecure-tls` or it never becomes Ready. `local-up.sh`
> patches this automatically. **Never do this on GKE** — there, metrics-server
> is managed and works out of the box.

**`top` works** → `resources.requests.cpu` is not set.

```bash
kubectl get deployment orders-api -n orders \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'
```

Utilisation is a percentage *of the request*. No request = no denominator = the
HPA cannot compute anything, and it fails open by never scaling.

```bash
helm upgrade ... --set resources.requests.cpu=50m
```

This is failure-lab scenario 13.

### 2. Metrics are valid but replicas don't move

```bash
kubectl describe hpa orders-api -n orders
```

Read the **Conditions** block — it states the reason explicitly:

| Condition | Meaning |
|---|---|
| `AbleToScale: False` · `reason: BackoffBoth` | In a cooldown window; wait |
| `ScalingActive: False` · `FailedGetResourceMetric` | Metrics problem → back to (1) |
| `ScalingLimited: True` · `TooManyReplicas` | **Already at `maxReplicas`** |
| `ScalingLimited: True` · `TooFewReplicas` | At `minReplicas`, wants fewer |

### 3. It decided to scale, but the pods can't start

```bash
kubectl get pods -n orders | grep Pending
kubectl describe pod PENDING_POD -n orders | tail -10
```

The HPA raised the replica count; the **scheduler** can't place the pods.
Autoscaling is capped by cluster capacity, and the HPA has no idea. Either the
cluster autoscaler adds a node, or you're stuck.

### 4. CPU isn't the bottleneck

The most commonly missed cause. If the service is slow because it's waiting on a
database, CPU stays low, the HPA sees no reason to scale, and adding pods
wouldn't help anyway — it would just add more connections to an already
overloaded database.

Scale on a metric that reflects the real constraint: requests-per-second, queue
depth, or p95 latency, via custom or external metrics.

### 5. Scale-down not happening

Expected. The 300s stabilisation window plus the 50%-per-minute policy means
scale-down is deliberately gradual. Wait before concluding it's broken.

### 6. Something else is fighting the HPA

If the Deployment also specifies `replicas`, Helm resets it on every upgrade and
the HPA sets it back — a visible scale blip on each deploy. **This chart omits
`replicas` entirely when `autoscaling.enabled` is true**, which is the fix.

Argo CD or Flux can cause the same fight; they need `ignoreDifferences` on
`spec.replicas`.

---

## Scaling on something other than CPU

### Memory — usually a trap

```yaml
autoscaling:
  targetMemoryUtilizationPercentage: 80
```

Most runtimes (JVM, Python, Go) **do not release memory** to the OS when load
drops. Memory goes up and stays up, so the HPA scales up and never back down.
Only use it when you know the workload's memory genuinely tracks load.

### Custom metrics — usually the right answer

For a web service, requests-per-second or p95 latency correlates with user
experience far better than CPU does.

```yaml
metrics:
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "100"
```

On GKE this needs the **Custom Metrics Stackdriver Adapter** plus Managed
Prometheus (which costs money beyond the free sample allowance).

### KEDA — event-driven

For queue-depth scaling (Pub/Sub, Kafka, RabbitMQ) and, uniquely, **scale to
zero**. The standard HPA cannot go below 1.

---

## Cluster Autoscaler

```hcl
autoscaling {
  min_node_count = 1
  max_node_count = 3      # your compute-cost ceiling
}
```

**Scales up** when pods are `Pending` due to insufficient resources.
**Scales down** when a node has been underutilised (<50%) for ~10 minutes *and*
its pods can be rescheduled elsewhere.

It will **refuse** to remove a node when:

- a pod has no controller (a bare pod, not managed by a Deployment/StatefulSet);
- a **PodDisruptionBudget** would be violated — this is failure-lab scenario 11,
  and it's also why an over-strict PDB quietly costs you money;
- a pod has local storage or restrictive affinity;
- the pod has the `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`
  annotation.

```bash
kubectl get configmap cluster-autoscaler-status -n kube-system -o yaml
gcloud container clusters describe CLUSTER --zone ZONE \
  --format='value(nodePools[0].autoscaling)'
```

> **Scaling up takes 1–3 minutes** — provision the VM, join the cluster, pull the
> image. If your traffic spike is faster than that, HPA + CA alone won't save
> you; you need headroom, pause pods, or pre-scaling ahead of a known event.

---

## Interview answers

**"How does the HPA decide how many replicas to run?"**
`desired = ceil(current × (currentUtilization / targetUtilization))`, evaluated
every 15 seconds, with a ±10% tolerance and configurable stabilisation windows.
Critically, **utilisation is measured against the CPU request** — not the limit,
not node capacity.

**"An HPA isn't scaling. Walk me through it."**
`kubectl top pods` first — that one command splits "metrics-server is broken"
from "requests.cpu is unset". Then `describe hpa` and read the Conditions.
Then: already at max? New pods Pending? And finally — is CPU actually the
bottleneck, or is the service I/O-bound and scaling wouldn't help anyway?

**"Why is scale-down slower than scale-up?"**
Asymmetric cost of being wrong. Scaling up late breaks your SLO; scaling up
early costs pennies. Scaling down eagerly causes flapping — removing a pod you
immediately need back, with a cold start each time.

**"Can you scale to zero?"**
Not with a standard HPA (`minReplicas` must be ≥ 1). KEDA can, and it's the
right tool for queue-driven or genuinely bursty workloads. The Cluster
Autoscaler *can* take a node pool to zero nodes.

**"HPA vs VPA vs Cluster Autoscaler?"**
Pod count, pod size, node count. HPA and VPA conflict on the same resource. HPA
and CA chain together: HPA creates pods, CA provides somewhere to put them.

---

## Practise it

```bash
./scripts/load-test.sh -n orders -d 180 -c 20   # watch it scale
./failure-lab/run.sh start 13                    # break it, then diagnose
kubectl describe hpa orders-api -n orders
```

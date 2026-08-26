# Architecture

## What was migrated

**`orders-api`** — an order-retrieval service for an e-commerce platform.

### Before: on-premises

```
   Users
     │
     ▼
   F5 load balancer  (hardware, shared, change requests take 3 days)
     │
     ├──► VM-01  orders-api  ─┐
     └──► VM-02  orders-api  ─┤
                              ├──► PostgreSQL (single instance, nightly dump)
                              └──► Redis (single instance)

   Deployment:  scp the tarball, ssh, systemctl restart, one VM at a time
   Rollback:    keep the previous tarball and hope
   Scaling:     file a ticket, wait two weeks for a VM
   Monitoring:  Nagios ping check + "is the port open"
   Version:     ssh in and read a text file
```

**The problems that justified the migration** — in the order they actually hurt:

1. **No rollback.** The previous release existed as a tarball on someone's
   laptop. Reverting was a 40-minute manual procedure under pressure.
2. **No answer to "what version is running?"** Two VMs could and did drift.
3. **No autoscaling.** Peak traffic was handled by permanently over-provisioning
   for it.
4. **Deploys caused downtime.** Restarting a VM dropped in-flight requests.
5. **A VM failure was an outage** until someone noticed and intervened.
6. **No useful observability.** "Is the port open" is not a health check.

### After: GKE

```
                 GitHub                          Google Cloud Platform
    ┌────────────────────────────┐   ┌──────────────────────────────────────────┐
    │  push tag v2.4.17          │   │                                          │
    │         │                  │   │   ┌────────────────────────────────┐     │
    │         ▼                  │   │   │  Artifact Registry             │     │
    │  GitHub Actions            │   │   │  orders-api:2.4.17             │     │
    │   lint → test → scan       │   │   │  IMMUTABLE TAGS                │     │
    │         │                  │   │   └───────────────┬────────────────┘     │
    │         │  OIDC token      │   │                   │ pull via              │
    │         ├──────────────────┼───┼──► Workload       │ Private Google Access │
    │         │  (no JSON key)   │   │    Identity       │ (no NAT, no cost)     │
    │         │                  │   │    Federation     ▼                      │
    │         ▼                  │   │   ┌────────────────────────────────┐     │
    │  build → push → deploy     │   │   │  GKE zonal, VPC-native          │     │
    │         │                  │   │   │  ┌──────────────────────────┐  │     │
    │         ▼                  │   │   │  │ namespace: orders        │  │     │
    │  VERIFY VERSION  ◄─────────┼───┼───┼──┤ Deployment · 2 replicas  │  │     │
    │  (digest must match)       │   │   │  │ HPA 2→5 · PDB · Service  │  │     │
    │         │                  │   │   │  │ ConfigMap · Secret ref   │  │     │
    │         ▼                  │   │   │  │ KSA ── Workload Identity │  │     │
    │  smoke test + validation   │   │   │  └──────────────────────────┘  │     │
    └────────────────────────────┘   │   │  node pool: 1× e2-small SPOT   │     │
                                     │   │  private nodes, no external IP │     │
    ┌────────────────────────────┐   │   └────────────────┬───────────────┘     │
    │  Terraform                 │──►│                    │                     │
    │  network │ gke │ ar │ iam  │   │      Cloud Logging │ Cloud Monitoring    │
    └────────────────────────────┘   │      (structured)  │ (dashboard, 8 alerts)│
                                     └──────────────────────────────────────────┘
```

---

## Component decisions

Every one of these is an interview question. The reasoning matters more than the
choice.

### Zonal cluster, not regional

A regional cluster replicates the control plane across three zones **and runs
your node pool in each of them** — so `node_count = 1` becomes three VMs and
triples the compute bill.

**Regional is right for production. Zonal is right for a cost-controlled
migration rehearsal.** Say exactly that in an interview; the wrong answer is
pretending zonal is production-grade.

The upgrade path is a cluster rebuild, which is itself a useful exercise.

### VPC-native (alias IPs), not routes-based

Required for Workload Identity, NEG-backed load balancing, and Private Google
Access to behave properly. Routes-based clusters are legacy.

**The part people get wrong:** VPC-native needs **two secondary IP ranges** — one
for pods, one for services — and **secondary ranges cannot be resized in place
while in use.** Undersize them and you rebuild the cluster to grow.

```
primary   10.0.0.0/20   nodes, internal load balancers
pods      10.4.0.0/14   262,144 addresses → ~1024 nodes at /24 per node
services  10.8.0.0/20   4,096 ClusterIPs
```

### Private nodes + Private Google Access, no Cloud NAT

Nodes have no external IP (free, strictly more secure). They still reach
Artifact Registry and Cloud Logging over Google's internal network via Private
Google Access.

**This is a security decision that also saves ~$32/month** — Cloud NAT is only
needed for egress to the *public* internet, which this workload doesn't need.

The control-plane endpoint stays public but restricted by
`master_authorized_networks`, so `kubectl` works from a laptop without a bastion.
Fully private endpoints require a bastion or VPN — correct for production,
disproportionate here.

### Spot VMs

60–91% cheaper; Google can reclaim the node with 30 seconds' notice.

Correct for a learning cluster and for genuinely stateless workloads. It also
*forces* you to build for a node vanishing — which is why `minReplicas: 2`, a
PDB, and topology spread all exist here rather than being decoration.

Never for a stateful tier.

### Artifact Registry with immutable tags

Container Registry (`gcr.io`) is deprecated; Artifact Registry is the only
correct choice for a 2026 migration.

**Immutable tags are the important part.** Once `:2.4.17` points at a digest, it
can never be moved. This single setting eliminates the entire class of "the
pipeline said SUCCESS but the old code is running" incidents, because a tag
becomes a version rather than a mutable pointer.

Registry location is forced to match the cluster region — otherwise every image
pull is billed as cross-region egress.

### Workload Identity everywhere, no service-account keys

A service-account JSON key never expires, works from anywhere on earth, and
appears in plaintext wherever it's pasted. It is the most common root cause of
real GCP compromises.

- **CI → GCP:** Workload Identity Federation. GitHub mints an OIDC token
  describing the exact repo and ref; GCP exchanges it for a ~1-hour token.
- **Pod → Google APIs:** the KSA is bound to a GSA; the metadata server issues
  short-lived tokens.

Both require a binding on *two* sides that must match exactly — the most common
misconfiguration, and failure-lab scenario 12.

→ [SECURITY.md](SECURITY.md)

### Helm, not raw manifests or Kustomize

The deciding factor is **release history**. `helm history` and `helm rollback`
give you a versioned, revertible record of what was deployed and when.
Kustomize has no equivalent — rollback means finding the previous commit and
re-applying, which is slower under pressure.

Environment differences are values overlays (`values-dev.yaml`,
`values-local.yaml`) layered on one base.

### ClusterIP, not LoadBalancer or Ingress

A LoadBalancer Service or Ingress provisions a Google Cloud load balancer at
~$18/month **billed at zero traffic**. For validating a deployment,
`kubectl port-forward` proves exactly the same thing for $0.

The Ingress template exists and is disabled by default. In real production this
would be an Ingress with a managed certificate and Cloud Armor.

---

## Application design

```
GET /            service identity
GET /health      LIVENESS   — is the process alive?         (never checks deps)
GET /ready       READINESS  — can it serve right now?       (does check deps)
GET /startup     STARTUP    — has it finished booting?
GET /version     build identity — the endpoint support lives on
GET /metrics     Prometheus exposition
GET /api/orders  the business endpoint
```

### The three probes answer three different questions

Using one endpoint and one set of thresholds for all three is the most common
probe mistake there is.

| Probe | Question | On failure | Tuning |
|---|---|---|---|
| **startup** | Has it booted? | Restart | Generous: 30 × 2s = 60s budget |
| **liveness** | Is the process wedged? | **Restart the container** | Forgiving: 3 × 10s |
| **readiness** | Send traffic now? | **Remove from Endpoints** | Twitchy: 2 × 5s |

**Liveness must never check dependencies.** If it did, a database blip would
restart every replica simultaneously — converting a partial outage into a total
one. Dependency checks belong in readiness, where failing is cheap: the pod is
removed from rotation, not destroyed, and recovers on its own.

While the **startup** probe is failing, liveness and readiness are suspended
entirely. That's what lets a slow-booting app coexist with an aggressive
liveness probe.

### `/version` — the reason this project exists

```json
{
  "application_version": "2.4.17",
  "git_commit": "7f3a9c2e1b4d8a6f5c3e2d1a9b8c7f6e5d4c3b2a",
  "build_timestamp": "2026-08-26T09:31:00Z",
  "container_image_tag": "2.4.17",
  "pod_name": "orders-api-9a1b2c-ghi",
  "environment": "dev"
}
```

These values are baked in at **Docker build time** via `--build-arg`, not read at
runtime. That's what makes them trustworthy: a running container can prove which
commit produced it.

Without this, verifying a deployment means asking Kubernetes about Kubernetes.

→ [docs/VERSION_VERIFICATION.md](docs/VERSION_VERIFICATION.md)

### Structured JSON logging

One JSON object per line, using Cloud Logging's field names (`severity`, not
`level`). Cloud Logging parses each key into an indexed field, which is the
difference between `jsonPayload.status>=500` and grepping free text.

Probe requests are deliberately **not** logged — pure ingestion cost, zero
information, and Cloud Logging bills per GiB past 50.

### Graceful shutdown — the 502-during-deploy fix

Pod deletion does two things **concurrently, not in order**:

1. kubelet starts terminating the container
2. the endpoints controller removes the pod from the Service

Step 2 propagates through kube-proxy on every node and is not instant. Without
mitigation, the container can be gone while nodes still route to it — which
users see as 502s on every deploy.

The fix is two-part:

- **`preStop: sleep 5`** — does nothing except give step 2 time to finish
- **the app flips readiness off *first*, then drains** — so it stops being a
  target before it stops working

`terminationGracePeriodSeconds: 30` comfortably exceeds preStop (5s) + drain (5s)
+ the longest in-flight request.

---

## Deployment topology

```
Namespace: orders

  Deployment orders-api
    replicas: 2 (HPA 2→5)          minimum that survives a node failure
    strategy: RollingUpdate
      maxUnavailable: 0            never drop below capacity during a deploy
      maxSurge: 1
    topologySpread: hostname, ScheduleAnyway
      │
      ├── Pod (node A)  ── ServiceAccount ── Workload Identity ── GSA
      └── Pod (node B)
            container orders-api
              non-root UID 10001, read-only rootfs, all caps dropped
              requests cpu 50m / mem 128Mi
              limits   cpu 500m / mem 128Mi
              probes: startup, liveness, readiness

  Service orders-api  (ClusterIP :80 → :8080)
  HPA                 2→5, 70% of CPU request
  PDB                 minAvailable: 1
  ConfigMap           non-secret config, hashed into the pod template
  Secret (referenced) ORDERS_DB_DSN
```

**`maxUnavailable: 0` with `maxSurge: 1`** — capacity is preserved throughout a
rollout. New pods must be Ready before old ones terminate.

**`ScheduleAnyway`, not `DoNotSchedule`** — on a single-node cluster,
`DoNotSchedule` would leave every replica after the first stuck `Pending`.

**`minAvailable: 1` with 2 replicas** — allows a node drain to evict one pod at a
time. Setting it equal to `replicaCount` makes the workload permanently
undrainable and stalls cluster upgrades (failure-lab scenario 11).

**Memory `request == limit`** gives the pod Guaranteed QoS, so it's the last
thing evicted under node pressure. CPU limit is deliberately far above the
request: throttling a latency-sensitive API to save CPU you aren't billed for is
a bad trade.

---

## CI/CD

```
git push tag v2.4.17
      │
      ├─ lint (ruff) ─ test (pytest) ─ bandit ─ pip-audit
      │
      ├─ docker build  (identity baked in via --build-arg)
      │       └─ ASSERT the baked-in version matches
      │       └─ ASSERT the image does not run as root
      │
      ├─ Trivy scan  (fails on CRITICAL)
      │
      ├─ OIDC auth to GCP  ← no JSON key
      │
      ├─ push to Artifact Registry
      │       └─ resolve the DIGEST — everything downstream uses this
      │
      ├─ helm upgrade --wait --atomic --set image.digest=...
      │       --wait   : block until pods are Ready
      │       --atomic : auto-rollback if they are not
      │
      ├─ kubectl rollout status
      │
      ├─ VERIFY VERSION  ← the gate that makes SUCCESS mean something
      │       9 layers, ending at the app's own /version
      │
      ├─ smoke test 20 requests against /api/orders
      │       (one request against a 30% failure rate passes 70% of the time)
      │
      └─ migration-validation.sh
```

**Terraform apply is deliberately not automatic.** This stack creates billable
GKE resources; auto-apply on merge is how a learning project produces a surprise
invoice. A human reads the plan and dispatches the workflow.

---

## What's deliberately not here

Being explicit about scope is more honest than an architecture diagram implying
completeness.

| Not included | Why | What production would do |
|---|---|---|
| Database | No stateful tier to migrate; Cloud SQL costs ~$10+/month minimum | Cloud SQL HA, PITR, read replicas, a failover runbook |
| Service mesh | One service has no mesh to speak of | Istio/ASM for mTLS, traffic splitting, circuit breaking |
| Multi-region | Doubles cost; adds no new *concepts* | Global LB, active/active stateless, active/passive data |
| Ingress + TLS | ~$18/month at zero traffic | GCE Ingress, managed certs, Cloud Armor WAF |
| Canary / progressive delivery | Needs a mesh or Argo Rollouts | 5% traffic for 10 min with automated metric analysis |
| Binary Authorization | Scope | cosign signing + a GKE policy refusing unsigned images |
| NetworkPolicy | One service has no meaningful pod-to-pod graph | Default-deny, explicit allows, Dataplane V2 |
| Remote Terraform state | One more resource to remember to delete | GCS backend, versioned, with state locking |

The templates and flags for Ingress, Managed Prometheus, Cloud NAT and flow logs
all exist — they're feature-flagged off with the cost documented, not absent.

---

## Where each concern lives

| Concern | File |
|---|---|
| Network, secondary ranges, firewall, NAT | `terraform/modules/network/` |
| Cluster, node pool, Workload Identity | `terraform/modules/gke/` |
| Registry, immutable tags, cleanup policies | `terraform/modules/artifact-registry/` |
| Service accounts, WIF, least privilege | `terraform/modules/iam/` |
| Deployment, probes, security context | `helm/application/templates/deployment.yaml` |
| Autoscaling | `helm/application/templates/hpa.yaml` |
| Build identity | `app/Dockerfile`, `scripts/build.sh` |
| Version verification | `scripts/verify-version.sh` |
| Pipeline | `.github/workflows/deploy-dev.yml` |
| Dashboards and alerts | `monitoring/` |

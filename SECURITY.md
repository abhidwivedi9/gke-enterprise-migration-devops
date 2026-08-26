# Security

This repository is **public**. Everything in it was written on the assumption
that anyone can read it, clone it, and grep its full git history.

---

## The central decision: no long-lived credentials, anywhere

There is not a single service-account JSON key in this project, and there is no
step in any runbook that tells you to create one.

A service-account key is a credential that:
- never expires,
- works from any IP address on earth,
- grants its roles to whoever holds the file,
- and appears in plaintext in whatever logs, CI output, or `git diff` it touches.

It is the single most common root cause of real GCP compromises. The only way to
guarantee a key doesn't leak is to not have one.

**Instead:**

| Who needs access | How they get it | Lifetime |
|---|---|---|
| GitHub Actions → GCP | Workload Identity Federation (OIDC) | ~1 hour |
| Application pod → Google APIs | Workload Identity (KSA → GSA) | minutes, auto-rotated |
| You, locally | `gcloud auth application-default login` | your session |
| GKE node → Artifact Registry | Node service account, repo-scoped reader | managed by GCP |

### How GitHub Actions authenticates without a key

```
GitHub Actions job
   │  requests an OIDC token describing this exact
   │  repo / ref / workflow / actor
   ▼
token.actions.githubusercontent.com   (issuer)
   │
   ▼
GCP Workload Identity Pool Provider
   │  validates the token AND enforces:
   │     attribute_condition = assertion.repository == 'OWNER/REPO'
   ▼
GCP Security Token Service
   │  exchanges it for a short-lived access token
   ▼
CI service account (orders-api-dev-ci-sa)
   │  roles/container.developer  ← can deploy workloads
   │  artifactregistry.writer    ← on ONE repository only
   ▼
No key was created, stored, or rotated at any point.
```

**The `attribute_condition` line is not optional.** Without it, *any* GitHub
repository on github.com — including one an attacker creates in thirty seconds —
can mint a token this provider accepts. This is the most commonly
misconfigured part of WIF, and it converts "keyless and secure" into "publicly
writable".

See [`terraform/modules/iam/main.tf`](terraform/modules/iam/main.tf).

---

## Container security

Enforced in [`app/Dockerfile`](app/Dockerfile) and
[`helm/application/values.yaml`](helm/application/values.yaml):

| Control | Setting | What it prevents |
|---|---|---|
| Non-root | `runAsUser: 10001`, `runAsNonRoot: true` | Container escape inherits an unprivileged user, not root |
| No privilege escalation | `allowPrivilegeEscalation: false` | setuid binaries can't gain more privilege than the parent |
| Read-only root filesystem | `readOnlyRootFilesystem: true` | An attacker can't drop a binary or modify code in place |
| All capabilities dropped | `capabilities.drop: [ALL]` | A web server needs none of the 14 default Linux capabilities |
| Seccomp | `RuntimeDefault` | Blocks ~300 rarely-needed syscalls |
| Resource limits | memory + CPU limits on every container | One workload can't starve a node — a real availability control |
| Minimal base | `python:3.12-slim-bookworm`, multi-stage | No compilers, no package manager cruft in the runtime layer |
| No token automount | `automountServiceAccountToken: false` | The pod doesn't carry a Kubernetes API credential it never uses |

> **The UID must match in two places.** The Dockerfile creates UID 10001 and the
> `securityContext` pins `runAsUser: 10001`. If they drift, the container starts
> as a user that cannot read its own files — a confusing failure that looks like
> a permissions bug in the application.

Verified in CI on every build: the pipeline fails if the image would run as root.

---

## Secrets

Three approaches, worst to best:

### 1. Chart-managed Secret — development only
```yaml
secrets:
  create: true
  data:
    ORDERS_DB_DSN: "..."
```
The value ends up in your values file, in your shell history if you used
`--set`, and in the Helm release Secret — recoverable via `helm get values` for
**every historical revision**. The chart annotates it with a warning for a
reason. Fine for a throwaway `kind` cluster; never for anything real.

### 2. Pre-created Secret — acceptable baseline
```bash
kubectl create secret generic orders-api-secrets -n orders \
  --from-literal=ORDERS_DB_DSN='...'
```
The chart references it and never sees the value. This is what most migrations
actually run on in week one. Its weaknesses: rotation is manual, there's no
audit trail, and base64 is *encoding, not encryption* — anyone with
`get secret` RBAC reads it in plaintext.

### 3. Secret Manager — the correct answer
The value never becomes a Kubernetes Secret at all. It's projected into the pod
at runtime, authenticated by Workload Identity, and rotates centrally with a
full audit log.

```bash
gcloud secrets create orders-db-dsn --replication-policy=automatic
echo -n 'postgresql://...' | gcloud secrets versions add orders-db-dsn --data-file=-

gcloud secrets add-iam-policy-binding orders-db-dsn \
  --member="serviceAccount:orders-api-dev-app-sa@PROJECT.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

Then mount via the [Secrets Store CSI driver](https://secrets-store-csi-driver.sigs.k8s.io/)
or sync with [External Secrets Operator](https://external-secrets.io/).

**Never** `helm upgrade --set secretValue=...`. It lands in shell history, in
CI logs, and in the Helm release forever.

---

## IAM: least privilege in practice

### The GKE node service account

GKE defaults to the **Compute Engine default service account**, which holds
`roles/editor` across the entire project. Any pod that escapes its container —
or simply reads the node metadata endpoint — inherits project-wide write access.

Replacing it is the highest-value, lowest-effort GKE hardening step that exists.
This project's node SA has exactly four roles:

```
roles/logging.logWriter
roles/monitoring.metricWriter
roles/monitoring.viewer
roles/stackdriver.resourceMetadata.writer
```

Artifact Registry read is granted **on the single repository**, not at project
level — so nodes can pull `orders-api` and nothing else.

### The CI service account

`roles/container.developer` lets CI deploy workloads but **not** create, modify,
or delete clusters. A pipeline should never be able to delete the cluster it
deploys to.

### Legacy metadata endpoints

`disable-legacy-endpoints=true` plus `GKE_METADATA` mode. Without these, any pod
can query the v1beta1 metadata API and steal the node service account's token —
which is precisely why the node SA's permissions matter so much.

---

## Network security

- **Private nodes** (`enable_private_nodes = true`) — nodes have no external IP.
  Free, and strictly more secure.
- **Private Google Access** — nodes reach Google APIs over Google's internal
  network. Security *and* cost benefit: no NAT gateway needed.
- **Master authorized networks** — restrict who can reach the Kubernetes API.
  **Set this.** Leaving `authorized_networks = []` leaves the control-plane
  endpoint reachable from the entire internet. Still authenticated, but exposed
  to credential stuffing and CVE scanning.
  ```hcl
  authorized_networks = [
    { cidr_block = "203.0.113.42/32", display_name = "my-laptop" }
  ]
  ```
- **Firewall rules** — the control-plane→webhook rule is scoped to the node tag
  and specific ports, not `0.0.0.0/0`.

### Not implemented, and why

**Egress deny-all.** Correct for a real production VPC, but it breaks image
pulls and Google API access in ways that are genuinely confusing to debug. It
belongs in a hardening exercise rather than a baseline someone is trying to
learn from. In production you would: default-deny egress, then explicitly allow
Artifact Registry, Google APIs (`199.36.153.8/30` for restricted VIP), and your
known dependencies.

**NetworkPolicy.** GKE Dataplane V2 gives you this for free. A production
deployment should default-deny pod-to-pod traffic and allow only what's needed.
Omitted here because a single-service demo has no meaningful pod-to-pod graph.

---

## Supply chain

| Stage | Control |
|---|---|
| Dependencies | Fully pinned in `requirements.txt`; `pip-audit` in CI |
| Source | `ruff` + `bandit` (fails on MEDIUM+) |
| Image | Trivy scan, **fails the build on CRITICAL** |
| Registry | **Immutable tags** — a tag can never be repointed |
| Deploy | Digest-pinned in the pipeline |
| Secrets | `gitleaks` on every push, plus a credential-filename check |

**Why Trivy fails on CRITICAL but only warns on HIGH:** base images routinely
carry HIGH findings with no available fix. A gate that blocks every release for
something unfixable gets disabled within a month, and then you have no gate at
all. Fail on what's actionable.

### Not implemented

**Image signing (Sigstore/cosign) and Binary Authorization.** The correct next
step for a real production migration — Binary Authorization would let GKE refuse
to run an unsigned image. Omitted here for scope; called out because "we don't
verify image provenance" is a real gap, not an oversight.

---

## Public repository checklist

Run before every push. CI enforces the automated parts.

- [ ] No `*.pem`, `*.key`, `*.p12`, `*.pfx` tracked
- [ ] No `service-account*.json` or any credential JSON
- [ ] No `.env` (only `.env.example`, with dummy values)
- [ ] No `terraform.tfstate` — **state files contain resource attributes and can
      contain secrets in plaintext**
- [ ] No `*.tfvars` (only `*.tfvars.example`)
- [ ] No kubeconfig files
- [ ] No real project IDs, billing account IDs, or internal hostnames
- [ ] No internal URLs, IP ranges, or employee names
- [ ] `gitleaks` clean across **full history**, not just HEAD

```bash
# Full history scan — a secret removed in a later commit is still in history
docker run --rm -v "$(pwd):/repo" zricethezav/gitleaks:latest detect \
  --source=/repo --verbose

# What is actually tracked
git ls-files | grep -E '\.(pem|key|p12|pfx)$|service-account.*\.json$|^\.env$'

# Search history for anything credential-shaped
git log -p --all | grep -E 'BEGIN [A-Z ]*PRIVATE KEY|"private_key"|AIza[0-9A-Za-z_-]{35}'
```

### If you ever commit a secret

**Rotate it first. Immediately.** Rewriting history is the *second* step, not the
first.

Public GitHub repositories are scraped continuously; a committed key is
typically found within minutes. Once pushed, assume it is compromised — forks,
caches, and third-party mirrors keep copies you cannot delete. Deleting the
commit does not un-leak it.

```bash
gcloud iam service-accounts keys delete KEY_ID --iam-account=SA_EMAIL
# then, and only then, purge history with git-filter-repo or BFG
```

---

## Threat model, briefly

| Threat | Mitigation | Residual risk |
|---|---|---|
| Leaked CI credential | No credential exists (WIF, ~1h tokens) | Compromised GitHub account could trigger a deploy — mitigate with environment protection rules |
| Container escape | Non-root, no caps, seccomp, read-only rootfs | Kernel 0-day; mitigate with GKE auto-upgrade + node auto-repair |
| Malicious image | Trivy gate, immutable tags, digest pinning | No signature verification — see Binary Authorization above |
| Stolen node SA token | Node SA has 4 narrow roles; legacy metadata disabled | Log/metric write access only |
| Public API endpoint | Master authorized networks | Only if you actually set them — the default is open |
| Secret in git | gitleaks + `.gitignore` + CI check | Human error; hence the rotate-first rule above |
| Excessive cost as DoS | `max_node_count`, HPA `maxReplicas`, budget alerts | Budgets alert but do not cap — see COST_CONTROL.md |

---

## Reporting a vulnerability

This is a portfolio/learning repository with no production deployment. If you
find a security problem in the code or in the guidance itself, please open a
GitHub issue. Do not include real credentials in the report.

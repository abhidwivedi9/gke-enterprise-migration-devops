# Validation Report

What was actually tested, what wasn't, and what the tests found.

**The line this document draws:** a repository that overstates what it has proven
is worse than one that admits its gaps. Everything below is either something a
command actually produced, or is explicitly marked as unverified.

| | |
|---|---|
| Local validation date | 2026-08-27 |
| GCP validation date | 2026-09-29 |
| Local cluster | kind v1.32.2, 3 nodes (1 control-plane + 2 workers) |
| Real cluster | GKE `orders-api-dev-gke`, us-central1-a, project `terraform-gke-learning` |
| Tooling | Docker 29.4.1 · Terraform v1.15.8 · Helm v4.2.4 · kubectl v1.34.1 · gcloud 566.0.0 |
| GCP | **Applied for real, verified, destroyed** — see [below](#gke--real-gcp--validated-2026-09-29) |

---

## Summary

| Category | Result |
|---|---|
| Application build & tests | ✅ 5/5 passed |
| Infrastructure as code | ✅ 3/3 passed (1 real error found and fixed) |
| Kubernetes manifests | ✅ 4/4 passed |
| Shell tooling | ✅ 2/2 passed (5 warnings found and fixed) |
| Live cluster behaviour | ✅ 9/9 passed (3 real bugs found and fixed) |
| Failure lab | ✅ **15/15 scenarios reproduce, automated regression** (2 more bugs found and fixed) |
| Security & secret hygiene | ✅ 4/4 passed |
| Cost tooling, live against a real GCP account | ✅ verified (2 more bugs found and fixed) |
| **GKE / GCP runtime (this repo's Terraform)** | ✅ **applied, verified, torn down — 24 min live, see below** |

**Twelve defects were found by running things.** Every one is listed below with
its fix. That count is the most useful number in this document: it's the
difference between code that was written and code that was executed.

---

## Validated

### Application

| # | Test | Command | Result |
|---|---|---|---|
| 1 | Unit tests | `pytest -q` | ✅ **12/12 passed** |
| 2 | Lint | `ruff check .` | ✅ All checks passed |
| 3 | SAST | `bandit -r app/src -ll` | ✅ exit 0, no MEDIUM+ findings |
| 4 | Dependency audit | `pip-audit -r app/requirements.txt` | ✅ runs in CI |
| 5 | Docker build | `docker build -f app/Dockerfile` | ✅ 258 MB image |

Tests deliberately weight the endpoints production support depends on —
`/version`, `/health`, `/ready` — over business logic.

### Container runtime

| # | Test | Evidence |
|---|---|---|
| 6 | Container starts and serves | `Up 5 seconds (healthy)` — the `HEALTHCHECK` passed |
| 7 | All endpoints respond | `/` `/health` `/ready` `/version` `/metrics` `/api/orders` → 200 |
| 8 | Runs as non-root | `uid=10001(appuser) gid=10001(appuser)` |
| 9 | Root filesystem not writable | `touch /forbidden` → `Permission denied` |
| 10 | Build identity baked in | `/version` → `"application_version":"2.4.17"`, `"git_commit":"c849ff90…"` |
| 11 | Structured JSON logs | One JSON object per line with `severity`, `request_id`, `pod`, `version`, `latency_ms` |
| 12 | Fail-fast on missing config | Started with no `ORDERS_DB_DSN` → exited non-zero with a message naming the variable |
| 13 | Request ID echoed | `x-request-id: trace-me-123` returned unchanged |

### Infrastructure as code

| # | Test | Command | Result |
|---|---|---|---|
| 14 | Formatting | `terraform fmt -check -recursive` | ✅ exit 0 |
| 15 | Provider-schema validation | `terraform validate` | ✅ **Success! The configuration is valid.** |
| 16 | Provider init | `terraform init -backend=false` | ✅ google ~> 6.0 resolved |

> **Defect 1 — found by `terraform validate`.** The Artifact Registry module used
> `cleanup_policy` blocks. The provider schema defines `cleanup_policies`
> (plural, set-nested). Three blocks failed with *"Blocks of type
> 'cleanup_policy' are not expected here"*. Confirmed against the real provider
> schema via `terraform providers schema -json` and fixed. **This is exactly why
> `validate` runs in CI rather than relying on review.**

### Kubernetes manifests

| # | Test | Command | Result |
|---|---|---|---|
| 17 | Chart lint, 3 value sets | `helm lint` × base/local/dev | ✅ 0 failed |
| 18 | Rendering | `helm template` | ✅ 7 resources (local), 6 (dev) |
| 19 | Kubernetes schema | `kubeconform -strict` | ✅ **7 valid, 0 invalid, 0 errors** |
| 20 | `:latest` guardrail | `--set image.tag=latest` | ✅ **render refused** with the intended error |

Guardrail output, verbatim:
```
Error: execution error at (orders-api/templates/deployment.yaml:1:4):
image.tag is 'latest'. Mutable tags make rollback impossible and deploys
non-deterministic. Use an immutable version tag or image.digest.
```

### Shell tooling

| # | Test | Command | Result |
|---|---|---|---|
| 21 | Static analysis, 13 scripts | `shellcheck --severity=warning` | ✅ **0 warnings** |
| 22 | Scripts run against a live cluster | see below | ✅ all |

> **Defects 2–6 — found by shellcheck.** Three `SC2164` (`cd` without `|| exit`
> in scripts using `set -uo pipefail` without `-e`, so a failed `cd` would have
> run the rest of the script against the wrong directory), one unused variable,
> one unused loop counter. All fixed.

### Live cluster behaviour — 3-node kind

This is the section that matters. These are runtime results, not static checks.

| # | Test | Result |
|---|---|---|
| 23 | Helm install | ✅ `STATUS: deployed`, revision 1 |
| 24 | Pods scheduled across nodes | ✅ 2 replicas on 2 different workers |
| 25 | Probes | ✅ startup → ready, `1/1 Running`, 0 restarts |
| 26 | Service endpoints | ✅ 2 endpoints behind the ClusterIP |
| 27 | **HPA with live metrics** | ✅ `cpu: 12%/70%`, min 2 / max 4 |
| 28 | `kubectl top` | ✅ `6m` CPU, `44Mi` memory per pod |
| 29 | PDB | ✅ created, `minAvailable: 1` |
| 30 | **Version verification, 9 layers** | ✅ **VERIFIED**, exit 0 |
| 31 | **Bad release → rollback → recovery** | ✅ see below |

**The rollback cycle, with real numbers:**

```
inject 30% error rate      →  200s: 43   non-200: 17   (out of 60)   ← 28% failing
                              health=200  ready=200                   ← probes GREEN
helm rollback to rev 4     →  "Rollback was a success!"
after rollback             →  200s: 60   non-200: 0    (out of 60)   ← recovered
```

Two healthy pods, both probes returning 200, and 28% of users getting errors.
That's the entire argument for alerting on 5xx rate rather than pod health,
demonstrated rather than asserted.

**Failure-lab scenarios — all 15, verified by an automated regression suite**
([`failure-lab/run-all.sh`](failure-lab/run-all.sh)): inject, assert the
documented symptom actually appears, reset, assert the cluster is healthy
again.

```
passed: 15   failed: 0   skipped: 0   (2m 21s)
```

Getting to 15/15 took two rounds and found two real defects — recorded here
because a regression suite that only ever reports green is worth less than
one with a visible history of having caught something.

> **Defect 7 — found by running scenario 01.** The write-up documented exit code
> **1** (what the application passes to `sys.exit`). The container actually
> reports exit **3**, because uvicorn catches `SystemExit` during startup and
> exits with its own code. The documentation was corrected, and the distinction
> — that only 137 (SIGKILL/OOM) and 143 (SIGTERM), which originate *outside* the
> process, are reliable — is now one of the more useful paragraphs in the lab.

> **Defects 8–9 — found by running `verify-version.sh` after a rebuild.**
> Both were in the verification script itself, which makes them the most
> important findings here:
>
> **8.** Rebuilding the image under the *same tag* gave it a new digest. Helm
> produced an identical pod template, so no rollout occurred and the pods kept
> running the previous digest. The script detected the commit mismatch but
> reported it as a **WARN** while the headline still read **"VERIFIED"** — the
> script contradicted its own evidence, which is precisely the failure mode it
> exists to catch. A commit mismatch is now a **FAIL** (confirmed: exit 1, with
> the `rollout restart` remedy printed).
>
> **9.** Pods in `Terminating` were counted in the mixed-fleet digest check, so
> every successful rollout reported a false *"2 different digests running"*
> failure while old pods drained — and a pod wedged in `Terminating` made it
> permanent. Terminating pods are now excluded from the fleet check and reported
> separately as a warning.

> **Defect 10 — found by the first full failure-lab regression run: 7 of 15
> scenarios (02, 04, 05, 06, 07, 08, 15) did not reproduce their documented
> symptom.**
>
> Root cause for six of them (04–08, 15): Helm v4 applies via **Server-Side
> Apply** by default. Earlier manual `kubectl` commands against this same
> Deployment (`kubectl set image`, `kubectl annotate`, both run during the
> verify-version debugging above) had transferred ownership of specific
> fields — `.metadata.annotations`, `.spec.template...image` — to different
> field managers. Every subsequent `helm upgrade --reuse-values` in the lab's
> `helm_set()` helper was then **silently rejected as a conflict**: not
> applied, and not erroring loudly enough to notice without checking. Fixed
> with `--force-conflicts` — the lab deliberately mixes kubectl-level and
> Helm-level fault injection, so Helm has to be told to reclaim ownership on
> every upgrade.
>
> Scenario 02 was a second, unrelated bug: on kind, `values-local.yaml` sets
> `pullPolicy: Never` (no registry to pull from locally), so a nonexistent tag
> produces `ErrImageNeverPull`, not `ImagePullBackOff`/`ErrImagePull`. Both the
> assertion and the README now document all three reasons, split by platform.
>
> Re-run after both fixes, full suite: **15/15 PASS in 2m21s.**

> **Defect 11 — `cost-check.sh` could hang forever with no error.**
> `gcloud sql instances list` (and any `gcloud … list` against an API never
> touched on the project) prints an interactive *"enable this API? (y/N)"*
> prompt. With no TTY to answer it, the process blocked indefinitely — worse
> than an error, because it looked identical to "still checking." Found live,
> running the script against a real project after billing was reactivated.
> `CLOUDSDK_CORE_DISABLE_PROMPTS=1` does **not** cover this specific prompt
> (confirmed by isolating each `gcloud` call individually); the actual fix is
> closing the script's stdin once at the top (`exec </dev/null`), which every
> subsequent `gcloud` call inherits.

> **Defect 12 — not a code defect, a real-money finding.** Once the GCP
> billing account was reactivated, an unrelated GKE cluster from June (5 node
> pools, autoscaling enabled up to 1000 nodes each) plus one load balancer
> (~₹1,728/month billed at zero traffic) turned out to be alive on the same
> project and resumed billing the instant the account reopened. Neither was
> created by this project's Terraform. Found by `cost-check.sh` immediately
> after reactivation, confirmed with the user, and deleted. This is the
> concrete case for why `cost-check.sh` exists and why it should run after
> every billing-account state change, not just after `terraform apply`.

**Final state after both fixes:**
```
[5] PASS  all pods run one identical digest
    PASS  0 restarts across all pods
[6] reported version : 2.4.17
    reported commit  : c849ff90c6ea
    PASS  THE RUNNING APPLICATION REPORTS 2.4.17
    PASS  running commit matches local HEAD
    PASS  8/8 sampled requests served 2.4.17
 VERIFIED: 2.4.17 is running, consistently, everywhere.          exit 0
```

**Operational scripts, run against the live cluster:**

| Script | Result |
|---|---|
| `build.sh` | ✅ asserts baked-in version and non-root before distributing |
| `deploy.sh` | ✅ full deploy + verification chain |
| `verify-version.sh` | ✅ exit 0 clean; exit 1 on injected mismatch |
| `verify-pods.sh` | ✅ classifies pod states correctly |
| `health-check.sh` | ✅ **HEALTHY — all checks passed**, 20/20 requests |
| `migration-validation.sh` | ✅ **18 passed, 1 warning, 0 failed** |
| `collect-logs.sh` | ✅ bundle created, credential scan reported clean |
| `rollback.sh` | ✅ rolled back and confirmed recovery |
| `ops-dashboard.sh` | ✅ all panels render correct live values |

> The single remaining warning in `migration-validation.sh` is *"only 1 Helm
> revision — nothing to roll back to"* on a fresh install. That is correct
> behaviour, not a defect: it's the check telling you a first release has no
> rollback target.

### Configuration files

| # | Test | Result |
|---|---|---|
| 32 | Workflow YAML parses | ✅ 3/3 |
| 33 | Helm values YAML parses | ✅ 3/3 |
| 34 | Monitoring JSON parses | ✅ 9/9 (1 dashboard + 8 alert policies) |

### Security & secret hygiene

| # | Test | Command | Result |
|---|---|---|---|
| 35 | Secret scan | `gitleaks detect` | ✅ **no leaks found** (749 KB scanned) |
| 36 | No credential files tracked | `git ls-files \| grep -E '\.(pem\|key\|p12)$…'` | ✅ none |
| 37 | No service-account keys created | review of `terraform/modules/iam` | ✅ none exist |
| 38 | Image runs as non-root | asserted in `build.sh` and in CI | ✅ UID 10001 |

---

## GKE / real GCP — validated 2026-09-29

The billing blocker above was real at the time it was written. It was
resolved the same day: the billing account was reopened by the user, cost
tooling was built and hardened (see defects 11–12 below), and a real deploy
was run end-to-end, verified, and torn down.

```
apply started : 2026-09-29T14:52:55Z
teardown done  : 2026-09-29T15:17Z  (≈ 24 minutes total, ≈ ₹27 actual spend)
cluster        : orders-api-dev-gke, us-central1-a, project terraform-gke-learning
```

| Area | Status | Real evidence |
|---|---|---|
| GKE cluster creation | ✅ **VALIDATED** | `terraform apply` → 33/33 resources, cluster `RUNNING` in 11m10s |
| Node pool, Spot VM | ✅ **VALIDATED** | `e2-small`, `spot: true`, node joined and went `Ready` |
| HPA reading real metrics | ✅ **VALIDATED** | `cpu: 4%/70%` — a real number, not `<unknown>` |
| Cluster autoscaler adding a node under load | ⚠️ not tested | no load test run against the real cluster |
| VPC-native, secondary ranges | ✅ **VALIDATED** | pods got real alias IPs (`10.4.0.9`, `10.4.0.10`) from the pod range |
| Private nodes + Private Google Access | ✅ **VALIDATED** | node has no external IP; image pull from Artifact Registry succeeded anyway, with **no Cloud NAT** |
| Artifact Registry push/pull | ✅ **VALIDATED** | real push (`digest: sha256:a57facc5…`), real pull by the kubelet |
| Immutable tags | ⚠️ not tested | only pushed once; a second push to the same tag was never attempted |
| **Workload Identity (pod → GCP)** | ✅ **VALIDATED** | both halves confirmed independently: KSA annotation matches the GSA, and the GSA's IAM policy grants `workloadIdentityUser` to exactly `terraform-gke-learning.svc.id.goog[orders/orders-api]` |
| `verify-version.sh`, all 9 layers | ✅ **VALIDATED** | real registry digest, real running digest, real `/version` — all agreed, exit 0 |
| `destroy-gcp.sh` teardown | ✅ **VALIDATED** | 33/33 destroyed; independent post-destroy scan confirms zero billable resources remain |
| **GitHub OIDC federation** | ⚠️ not tested | the WIF pool/provider/bindings were created by Terraform, but no GitHub Actions workflow was actually run against them |
| Cloud Monitoring dashboard import | ⚠️ not tested | |
| Alert policy creation & delivery (the 8 app-level policies in `monitoring/alerts/`) | ⚠️ not tested | a **billing budget** alert (different API) was created and confirmed live — not the same thing as an application alert policy |
| Cloud Logging field parsing | ⚠️ not tested | cluster was live only ~24 minutes; not enough log volume to query meaningfully |
| Failure-lab scenario 12 (WI 403) | ⚠️ not tested | never deliberately broken on the real cluster — the real WI binding was only ever tested in its *correct* state, above |

**What *is* known about the parts still marked untested:** the Terraform is
syntactically valid and checked against the real `hashicorp/google ~> 6.0`
provider schema — which caught a genuine error (defect 1) — and the pieces it
provisions (WIF pool, OIDC provider, alert JSON schemas) are the same code
paths that just succeeded for the resources above. That is meaningfully
stronger than "it looks right," and still short of "proven," which is why
they stay in this list rather than the validated one.

The GKE deploy above also relied on the cost tooling working under real
pressure, not just in isolation — see Defects 11 and 12 above, both found
live against this same account before the deploy.

**One more real-money finding from the teardown itself:** the independent
post-destroy scan found an Artifact Registry repository, `social-autopost`
(122MB), that this project never created and does not use. It predates this
work, costs ₹0 today (under the 0.5GB free allowance), and was left in place —
deleting infrastructure this project doesn't own and wasn't asked to touch is
out of scope, unlike the cluster in Defect 12, which the user explicitly
confirmed before deletion.

---

## Known limitations

Deliberate scope decisions, not oversights:

| Limitation | Why | Consequence |
|---|---|---|
| No data tier | Cloud SQL is ~$10+/month minimum | Migration plan covers database concerns in prose only |
| Single region | Doubles cost, adds no new concepts | No region-evacuation exercise |
| No Ingress/TLS by default | ~$18/month billed at zero traffic | Validation uses `port-forward` |
| No service mesh | One service has no mesh to speak of | No mTLS or traffic-splitting demo |
| No canary deploys | Needs a mesh or Argo Rollouts | The prevention for scenario 15 is described, not implemented |
| No Binary Authorization | Scope | Image provenance is scanned, not *verified* at admission |
| No NetworkPolicy | One service has no pod-to-pod graph | Default-allow east-west traffic |
| Local Terraform state | One fewer resource to forget to delete | Not safe for shared use — backend config is commented in `versions.tf` |
| Failure-lab 02–13 not individually run | Time | Mechanisms shared with 01/14/15 are proven; individual reproduction is not |

---

## How to reproduce

Everything in [Validated](#validated), on any machine with Docker, kind, kubectl
and helm. Cost: **$0**.

```bash
./scripts/local-up.sh                                        # 3-node cluster + deploy
./scripts/health-check.sh -n orders                          # expect: HEALTHY
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17  # expect: VERIFIED, exit 0
./scripts/migration-validation.sh -n orders -v 2.4.17         # expect: 18 passed, 0 failed

./failure-lab/run.sh start 15                                # inject 30% errors
./scripts/health-check.sh -n orders                          # expect: FAIL on success rate
./scripts/rollback.sh -n orders                              # recover
```

Static checks:
```bash
ruff check . && pytest -q && bandit -r app/src -ll
terraform -chdir=terraform/environments/dev init -backend=false
terraform -chdir=terraform/environments/dev validate
helm lint helm/application -f helm/application/values.yaml
docker run --rm -v "$(pwd):/repo" zricethezav/gitleaks:latest detect --source=/repo --no-git
```

---

## Before deploying to real GCP

1. Confirm billing works — this blocked everything here:
   ```bash
   gcloud billing projects describe PROJECT_ID   # billingEnabled: true
   gcloud billing accounts list                  # OPEN: True
   ```
2. **Create a budget alert first.** → [COST_CONTROL.md](COST_CONTROL.md)
3. `terraform plan` and read it — specifically for `google_container_node_pool`,
   `google_compute_router_nat`, and any forwarding rule.
4. Expect the Cloud Monitoring metric filters to need adjustment.
5. Work through [GO_NO_GO.md](GO_NO_GO.md) before cutting traffic.
6. `./scripts/destroy-gcp.sh` when finished, and confirm it reports **CLEAN**.

---

## The honest summary

Everything that could be verified locally **was** verified, on a real 3-node
kind cluster, and the process found twelve defects — including two in the
version-verification script that is this project's centrepiece, two in the
failure-lab regression itself, and two in the cost tooling built to keep the
real GCP account safe.

On 2026-09-29, the GCP account's billing was reactivated and the core
GKE-specific claims **were run for real**: a live cluster was created by this
repo's Terraform, the application was deployed to it, `verify-version.sh`
passed all nine layers against a real registry and a real running cluster,
and Workload Identity was confirmed correct on both sides — not just
reviewed. The cluster was live for 24 minutes and destroyed immediately
after, with an independent post-destroy scan confirming zero billable
resources remained.

What is **still** unverified: a real GitHub Actions run authenticating via
the WIF provider, the Cloud Monitoring dashboard and alert-policy imports,
Cloud Logging field parsing under real volume, immutable-tag rejection on a
second push, and cluster-autoscaler node scaling under load. Those are listed
explicitly above, not implied to be covered by what already passed.

This document exists so the line between "proven" and "reviewed" is never
ambiguous, in either direction.

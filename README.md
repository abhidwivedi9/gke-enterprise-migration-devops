# GKE Enterprise Migration — DevOps & Production Support

**An enterprise order-management API migrated from on-premises VMs to Google
Kubernetes Engine, and the complete operational toolkit for running it
afterwards.**

This is not a tutorial repository. It is built the way the job is actually done:
infrastructure as code, a real CI/CD pipeline with keyless authentication,
version verification that catches the deploys nobody notices are wrong, a
15-scenario failure lab, and runbooks written to be opened during an incident
rather than read on a Sunday.

[![Build and Test](https://github.com/abhidwivedi9/gke-enterprise-migration-devops/actions/workflows/build-test.yml/badge.svg)](../../actions)
&nbsp;·&nbsp; License: Apache-2.0
&nbsp;·&nbsp; Cost at rest: **$0** (local) · ~**$5–7/month** (GKE, defaults)

---

## The scenario

`orders-api` is an existing production service — a Python API handling order
retrieval for an e-commerce platform. It runs on two on-prem VMs behind an
F5 load balancer, is deployed by a shell script over SSH, and has no autoscaling,
no rollback story, and no way to answer "which version is actually running?"

**My role:** the DevOps engineer responsible for migrating it to GCP/GKE and
supporting it in production afterwards.

That means the interesting work isn't the migration itself. It's everything
after: *"deploy 2.4.17"*, *"pods are restarting"*, *"users are getting 500s"*,
*"what version is running?"*, *"roll it back"*.

---

## Architecture

```
                 GitHub                          Google Cloud Platform
    ┌────────────────────────────┐   ┌──────────────────────────────────────────┐
    │  push tag v2.4.17          │   │                                          │
    │         │                  │   │   ┌────────────────────────────────┐     │
    │         ▼                  │   │   │  Artifact Registry             │     │
    │  GitHub Actions            │   │   │  orders-api:2.4.17             │     │
    │   lint → test → scan       │   │   │  (immutable tags)              │     │
    │         │                  │   │   └───────────────┬────────────────┘     │
    │         │  OIDC token      │   │                   │ pull (Private        │
    │         ├──────────────────┼───┼──► Workload       │  Google Access)      │
    │         │  (no JSON key)   │   │    Identity       │                      │
    │         │                  │   │    Federation     ▼                      │
    │         ▼                  │   │   ┌────────────────────────────────┐     │
    │  build → push → deploy     │   │   │  GKE (zonal, VPC-native)       │     │
    │         │                  │   │   │  ┌──────────────────────────┐  │     │
    │         ▼                  │   │   │  │ namespace: orders        │  │     │
    │  VERIFY VERSION  ◄─────────┼───┼───┼──┤  Deployment  2 replicas  │  │     │
    │  (digest must match)       │   │   │  │  HPA         2→5         │  │     │
    └────────────────────────────┘   │   │  │  PDB, Service, ConfigMap │  │     │
                                     │   │  │  Workload Identity KSA   │  │     │
    ┌────────────────────────────┐   │   │  └──────────────────────────┘  │     │
    │  Terraform                 │──►│   │   node pool: 1× e2-small SPOT  │     │
    │  network │ gke │ ar │ iam  │   │   └────────────────┬───────────────┘     │
    └────────────────────────────┘   │                    │                     │
                                     │      Cloud Logging │ Cloud Monitoring    │
                                     │      (structured)  │ (dashboard+alerts)  │
                                     └──────────────────────────────────────────┘
```

Full detail: **[ARCHITECTURE.md](ARCHITECTURE.md)**

---

## What's in here

| Layer | What it does | Where |
|---|---|---|
| **Application** | Python/FastAPI. `/health` `/ready` `/startup` `/version` `/metrics`, structured JSON logs, env-driven fault injection | [`app/`](app/) |
| **Container** | Multi-stage, non-root UID 10001, read-only rootfs, build identity baked in at build time | [`app/Dockerfile`](app/Dockerfile) |
| **Infrastructure** | Terraform: VPC + secondary ranges, zonal GKE, Artifact Registry, least-privilege IAM, GitHub OIDC | [`terraform/`](terraform/) |
| **Deployment** | Helm chart: 3 probes, HPA, PDB, topology spread, `checksum/config`, `:latest` guardrail | [`helm/`](helm/) |
| **CI/CD** | Build → test → scan → push → deploy → **verify** → validate. Keyless via WIF | [`.github/workflows/`](.github/workflows/) |
| **Operations** | 10 scripts: build, deploy, rollback, verify-version, verify-pods, collect-logs, health-check, migration-validation, load-test, destroy-gcp | [`scripts/`](scripts/) |
| **Monitoring** | Cloud Monitoring dashboard JSON + 8 alert policies, with a guide to reading each panel | [`monitoring/`](monitoring/) |
| **Failure lab** | 15 injectable failures, each with symptom → root cause → fix → interview question | [`failure-lab/`](failure-lab/) |

---

## Run it locally — $0, no GCP account

Everything except the GCP-specific pieces runs on a local `kind` cluster.

**Prerequisites:** Docker, `kind`, `kubectl`, `helm`.

```bash
./scripts/local-up.sh
```

That creates a 3-node cluster, installs metrics-server, builds the image,
deploys the chart, and verifies the running version end to end. Then:

```bash
./scripts/health-check.sh -n orders          # the 60-second "is it healthy?" sweep
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17
./scripts/load-test.sh -n orders             # watch the HPA scale
./failure-lab/run.sh list                    # break it on purpose
```

Tear down: `kind delete cluster --name orders-lab`

## Deploy to GCP

> **Read [COST_CONTROL.md](COST_CONTROL.md) first.** GKE nodes bill hourly
> whether or not traffic reaches them. Nothing here creates a resource without
> you explicitly running `terraform apply`.

```bash
cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars   # fill in your project ID
terraform init && terraform plan                # READ THE PLAN
terraform apply                                 # ← this is where billing starts
```

Then follow **[MIGRATION_PLAN.md](MIGRATION_PLAN.md)** for the cutover, and
**[GO_NO_GO.md](GO_NO_GO.md)** before declaring it done.

**When you finish, always:**
```bash
./scripts/destroy-gcp.sh
```
It destroys via Terraform *and then independently verifies* nothing billable
survived — because Terraform only knows about what's in its state file.

---

## The problem this project is really about

A deployment can report SUCCESS at every single layer and still be running the
wrong code.

Helm says `deployed`. The Deployment says 3/3 available. `kubectl rollout status`
says successfully rolled out. GitHub Actions is green. And the application is
serving last week's build — because the tag was mutable, or a node reused a
cached layer, or the rollout is half-finished and *some* pods are new.

[`scripts/verify-version.sh`](scripts/verify-version.sh) walks all nine layers
and refuses to agree with any of them until the running process itself confirms:

```
Git commit → image tag → registry digest → Helm release → Deployment spec
  → ReplicaSet → Pod spec → running container digest → GET /version
```

Real output against a live cluster:

```
[5] Pods: reconcile requested image vs the digest actually running
      orders-api-cdf4ff75b-2kwjd  [Running]
          spec  : orders-api:2.4.17
          running: sha256:afc19f2833cea286e2dc28b58124c7cc89450f872608e917ce77374750d64fbd
     PASS  all pods run one identical digest
[6] Application /version — ask the running process directly
     PASS  THE RUNNING APPLICATION REPORTS 2.4.17
     PASS  8/8 sampled requests served 2.4.17
```

Why it matters, and every way it goes wrong:
**[docs/VERSION_VERIFICATION.md](docs/VERSION_VERIFICATION.md)**

---

## Documentation

**Do the work**
- [REAL_DEVOPS_SUPPORT_WORKFLOW.md](REAL_DEVOPS_SUPPORT_WORKFLOW.md) — "deploy 2.4.17", start to finish, 17 steps
- [RELEASE_RUNBOOK.md](RELEASE_RUNBOOK.md) · [ROLLBACK_RUNBOOK.md](ROLLBACK_RUNBOOK.md) · [OPERATIONS_RUNBOOK.md](OPERATIONS_RUNBOOK.md)
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — 15 pod failure modes, each symptom → command → fix → prevention

**Migrate**
- [MIGRATION_PLAN.md](MIGRATION_PLAN.md) — discovery, pre-migration, cutover, post-migration
- [GO_NO_GO.md](GO_NO_GO.md) — 16 gates with owner and evidence

**Investigate**
- [docs/LOGGING_GUIDE.md](docs/LOGGING_GUIDE.md) — kubectl logs and Cloud Logging queries
- [docs/INCIDENT_HTTP_500.md](docs/INCIDENT_HTTP_500.md) — walking the request path, LB → dependency
- [docs/AUTOSCALING.md](docs/AUTOSCALING.md) — HPA, and why it isn't scaling
- [monitoring/DASHBOARD_GUIDE.md](monitoring/DASHBOARD_GUIDE.md) — every panel, and what to do when it moves

**Reference**
- [GCP_COMMAND_REFERENCE.md](GCP_COMMAND_REFERENCE.md) · [KUBECTL_COMMAND_REFERENCE.md](KUBECTL_COMMAND_REFERENCE.md) — organised by *when* you'd run them
- [SECURITY.md](SECURITY.md) · [COST_CONTROL.md](COST_CONTROL.md) · [CONTRIBUTING.md](CONTRIBUTING.md)

**Interview**
- [INTERVIEW_GUIDE.md](INTERVIEW_GUIDE.md) — 5-minute and 15-minute walkthroughs
- [docs/INTERVIEW_QUESTIONS.md](docs/INTERVIEW_QUESTIONS.md) — 100 scenario questions with senior-level answers
- [docs/STUDY_PLAN_7_DAY.md](docs/STUDY_PLAN_7_DAY.md)

---

## What has actually been verified

This repository draws a hard line between "tested" and "written but not run."
Every claim is recorded in **[VALIDATION_REPORT.md](VALIDATION_REPORT.md)**.

| | |
|---|---|
| ✅ **Verified on a real cluster** | Docker build, container smoke test, 12/12 unit tests, ruff, bandit, `terraform validate`, `helm lint`/`template`, 3-node kind deploy, HPA scaling with live metrics, failure-lab scenarios, a real bad-release → rollback → recovery cycle |
| ⚠️ **Not verified — requires a billable GCP account** | GKE cluster creation, Artifact Registry push/pull, Workload Identity, GitHub OIDC federation, Cloud Monitoring dashboard import |

Nothing in this repository claims a GCP deployment succeeded. The Terraform is
schema-valid and reviewed; it has not been applied against a live billing
account.

---

## Security

Public-repo safe by construction. No credentials, no service-account keys, no
real project IDs. CI authenticates to GCP via **Workload Identity Federation** —
there is no long-lived key to leak. `gitleaks` and a credential-file check run
on every push.

Full posture and the pre-publication checklist: **[SECURITY.md](SECURITY.md)**

---

## License

Apache-2.0 — see [LICENSE](LICENSE).

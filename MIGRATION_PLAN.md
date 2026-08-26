# Migration Plan

Migrating `orders-api` from two on-premises VMs to GKE.

Four phases: **Discovery → Pre-migration → Migration → Post-migration.**

The unglamorous truth of migration work: **discovery is where migrations
succeed or fail.** Almost every failed cutover traces back to something nobody
wrote down in phase 1 — a hard-coded IP, a cron job on one VM, a firewall rule
that only allowed the old subnet.

---

# Phase 1 — Discovery

You cannot migrate what you have not inventoried. Do this before touching any
infrastructure.

## Application

| Item | Finding | How to confirm |
|---|---|---|
| Language / runtime | Python 3.12, FastAPI, uvicorn | `cat requirements.txt` |
| Current version | 2.4.16 | `curl http://vm-01:8080/version`, or read the deploy script |
| Start command | `uvicorn app.src.main:app --port 8080` | `systemctl cat orders-api` |
| Runs as | root ⚠️ | `ps aux \| grep orders` |
| Stateless? | **Yes** — no local session or file state | Code review + `lsof` on the running process |
| Startup time | ~3 s | Restart it and time it |
| Graceful shutdown? | **No** ⚠️ | Send SIGTERM, watch for dropped requests |
| Memory at peak | ~180 MB | `ps`, or existing monitoring |
| CPU at peak | ~0.4 core | same |

> **"Stateless?" is the question that determines whether this is a two-week or a
> six-month migration.** Local file writes, in-memory sessions, or singleton
> background jobs all need redesign before the workload can run multi-replica.
> `orders-api` is genuinely stateless, which is why this is a small migration.

Two ⚠️ items to fix *during* migration, not after: running as root, and no
graceful shutdown (which will cause 502s on every rolling update).

## Dependencies

| Dependency | Current | Target | Migration action |
|---|---|---|---|
| PostgreSQL | on-prem, single instance | Cloud SQL (out of scope here) | Connectivity + DSN via Secret Manager |
| Redis | on-prem, single | Memorystore | Same |
| Payments API | third-party HTTPS | unchanged | **Confirm their IP allowlist** — the new egress IP will differ |
| Internal auth service | `http://auth.internal:9000` | unchanged | Needs VPN/Interconnect, or migrate too |

> **The dependency that breaks cutovers:** a third-party allowlisting your *old*
> egress IP. Nobody remembers until requests start failing at 02:00. Ask every
> external provider whether they allowlist, and get the new IP allowlisted
> **before** cutover.

## Ports, DNS, certificates

| Item | Current | Target |
|---|---|---|
| App port | 8080 | 8080 (containerPort) |
| External | `orders.company.com` → F5 VIP | → GCLB IP |
| TLS | wildcard cert, manual renewal, **expires in 4 months** | Google-managed cert |
| DNS TTL | **3600 s** ⚠️ | **Lower to 60 s at least 24h before cutover** |

> **Lower the DNS TTL a day in advance.** With a 3600 s TTL, a rollback that
> requires a DNS change takes an hour to propagate — which is not a rollback, it
> is an outage with extra steps.

## Configuration and secrets

```bash
# On the current VM — inventory everything the app reads
systemctl cat orders-api | grep -i environment
cat /etc/orders-api/config.env
```

| Item | Current | Target |
|---|---|---|
| Non-secret config | `/etc/orders-api/config.env` | ConfigMap |
| DB password | **plaintext in that same file** ⚠️ | Secret Manager + Workload Identity |
| API key (payments) | same file ⚠️ | Secret Manager |
| TLS private key | on disk, world-readable ⚠️ | Google-managed certificate |

**Every secret found on the old VMs must be rotated during migration.** They have
sat in plaintext on a shared filesystem for years; treat them as compromised.

## Network and firewall

| Rule | Current | Target |
|---|---|---|
| Ingress 8080 | from F5 subnet only | GKE Service → pods |
| Egress → PostgreSQL:5432 | from VM subnet | from pod IP range — **the CIDR changes** |
| Egress → payments API | from VM NAT IP | **new egress IP** — allowlist it first |

> **The pod CIDR is not the node CIDR.** Any firewall rule written against the
> old VM subnet must be re-written against the *pod* secondary range
> (`10.4.0.0/14`). Missing this produces connection timeouts that look like
> application bugs.

## Current operations

| Concern | Today | After |
|---|---|---|
| Deploy | `scp` + `ssh` + `systemctl restart`, one VM at a time | Helm, rolling update |
| Rollback | previous tarball, ~40 min manual | `helm rollback`, ~3 min |
| Scaling | file a ticket, wait 2 weeks | HPA, ~30 s |
| Monitoring | Nagios port check | Cloud Monitoring + 8 alerts |
| Logs | `ssh` + `grep /var/log/orders-api.log` | Cloud Logging, structured, queryable |
| Version check | `ssh` and read a file | `curl /version` + `verify-version.sh` |
| On-call runbook | none | this repository |

## Rollback strategy for the migration itself

**Keep the old VMs running, serving nothing, for two weeks.**

Rollback = point DNS back at the F5 VIP. That's it. Do not decommission until
the new platform has survived a full business cycle including a peak day and a
month-end close.

This is the cheapest insurance in the entire project.

---

# Phase 2 — Pre-migration

## GCP readiness

- [ ] Project created, **billing enabled** — verify explicitly:
      ```bash
      gcloud billing projects describe PROJECT_ID   # billingEnabled: true
      gcloud billing accounts list                  # OPEN: True
      ```
      > A closed billing account blocks everything and produces error messages
      > that look like permission problems. Check this first — it is exactly
      > what blocked real GCP validation of this project.
- [ ] **Budget alert created** before any resource exists → [COST_CONTROL.md](COST_CONTROL.md)
- [ ] APIs enabled (Terraform does this): compute, container, artifactregistry,
      iam, iamcredentials, sts, logging, monitoring, cloudresourcemanager
- [ ] Quotas checked for the target region (CPUs, in-use IPs, SSD)

## Networking

- [ ] VPC + subnet with **two secondary ranges**, sized for growth — they cannot
      be resized in place while in use
- [ ] Private Google Access **on** (free registry + logging access, no NAT)
- [ ] Firewall: control plane → node webhook ports
- [ ] Firewall rules for dependencies rewritten against the **pod** CIDR
- [ ] `master_authorized_networks` set to your IP, not left empty
- [ ] Connectivity to on-prem dependencies proven (VPN / Interconnect) **before**
      the cluster exists

## Identity and security

- [ ] Node service account created — **not** the Compute Engine default, which
      holds project-wide Editor
- [ ] Workload Identity enabled on cluster and node pool (`GKE_METADATA`)
- [ ] Application GSA + KSA binding — **both halves**, namespace and name matching
      exactly
- [ ] GitHub OIDC pool with `attribute_condition` pinned to your repository
      > Without the condition, **any** GitHub repo can mint an accepted token.
- [ ] All secrets rotated and stored in Secret Manager
- [ ] No service-account JSON key created anywhere

## Registry and CI/CD

- [ ] Artifact Registry in the **same region as the cluster** (cross-region pulls
      are billed)
- [ ] Immutable tags enabled
- [ ] Cleanup policy configured (start in dry-run)
- [ ] Pipeline runs green end to end on a test tag
- [ ] Pipeline includes a **version-verification gate**, not just a deploy step

## Application changes required

These are code changes, and they need to land before cutover:

- [ ] **Graceful SIGTERM handling** — flip readiness off, then drain
- [ ] **`/health`, `/ready`, `/startup`** as three distinct endpoints
- [ ] **`/version`** exposing build identity baked in at build time
- [ ] **Structured JSON logging** to stdout — not to a file
- [ ] **Config from environment**, no file reads
- [ ] **Non-root container**, fixed UID matching the securityContext
- [ ] **Resource requests and limits** derived from measured usage

> Items 1 and 5 are the two that most often get skipped and most often cause
> post-migration incidents: 502s on every deploy, and a config file that doesn't
> exist inside the container.

## Observability

- [ ] Dashboard imported
- [ ] Alerts created **and attached to a notification channel** — a policy with
      no channel fires into the void
- [ ] Log-based metrics for 5xx and pod-failure events
- [ ] **Baselines recorded from the OLD system**: p50/p95/p99 latency, error
      rate, requests/sec at peak

> **Record the baselines.** Post-migration you will be asked "is it slower?" and
> "is the error rate higher?" Without pre-migration numbers, those questions are
> unanswerable and every discussion becomes opinion.

## Rehearse

- [ ] Full deploy to a non-production namespace
- [ ] **Rollback rehearsed** — `helm rollback`, timed
- [ ] Node drain tested (catches an over-strict PDB before it stalls an upgrade)
- [ ] HPA verified under load
- [ ] Failure lab worked through — [failure-lab/](failure-lab/)

---

# Phase 3 — Migration

## Cutover approach: parallel run, then DNS

```
  Stage 1   Deploy to GKE. Send it NO production traffic.
            Validate against the internal endpoint only.
              │
  Stage 2   Mirror or synthetic traffic. Compare behaviour with prod.
              │
  Stage 3   DNS weighted 10% → GKE. Watch for 30 minutes.
              │
  Stage 4   50%. Watch for an hour.
              │
  Stage 5   100%. Old VMs stay running, serving nothing, for 2 weeks.
```

**Why not a big-bang cutover:** the 10% stage limits blast radius to a tenth of
users, and the rollback is a DNS weight change rather than a redeploy.

## Cutover runbook

| # | Step | Command | Rollback |
|---|---|---|---|
| 1 | Freeze changes to the old system | announce | n/a |
| 2 | Confirm DNS TTL is 60 s | `dig orders.company.com` | n/a |
| 3 | `terraform apply` | `cd terraform/environments/dev && terraform apply` | `./scripts/destroy-gcp.sh` |
| 4 | Verify cluster | `gcloud container clusters describe ...` | — |
| 5 | Create secrets in Secret Manager | `gcloud secrets create ...` | — |
| 6 | Build + push image | `./scripts/build.sh 2.4.17 --push --registry ...` | — |
| 7 | Verify image and digest | `gcloud artifacts docker images describe ...` | — |
| 8 | Deploy | `./scripts/deploy.sh 2.4.17 --env dev --registry ...` | `./scripts/rollback.sh` |
| 9 | **Verify version** | `./scripts/verify-version.sh -n orders -v 2.4.17` | — |
| 10 | Smoke test | `./scripts/health-check.sh -n orders` | — |
| 11 | Full validation | `./scripts/migration-validation.sh -n orders -v 2.4.17` | — |
| 12 | **GO/NO-GO decision** | [GO_NO_GO.md](GO_NO_GO.md) | **STOP HERE if any FAIL** |
| 13 | DNS 10% | at your DNS provider | revert DNS weight |
| 14 | Watch 30 min | dashboard + `ops-dashboard.sh --watch` | revert DNS |
| 15 | DNS 50% → 100% | | revert DNS |
| 16 | Monitor 24 h | | revert DNS |
| 17 | Decommission old VMs — **after 2 weeks** | | *none — this is the point of no return* |

**Step 12 is a real gate.** If any GO/NO-GO item is FAIL, you stop. The cost of
delaying a cutover by a week is always lower than the cost of a bad one.

## During cutover — watch these

```bash
./monitoring/ops-dashboard.sh -n orders --watch
```

| Signal | Abort if |
|---|---|
| 5xx rate | above the old system's baseline |
| p95 latency | more than ~20% above baseline |
| Pod restarts | any |
| Replicas available | below desired for more than 2 min |
| Dependency errors | any connection failures to DB / payments |

**Have the rollback command in a terminal already typed** before you change DNS.

---

# Phase 4 — Post-migration

## First hour

```bash
./scripts/migration-validation.sh -n orders -v 2.4.17
```

- [ ] Pods healthy, zero restarts
- [ ] Error rate at or below baseline
- [ ] p95 latency within 20% of baseline
- [ ] Correct version confirmed via `/version`, sampled repeatedly
- [ ] Logs flowing into Cloud Logging with parsed fields
- [ ] No unexpected dependency errors
- [ ] **Business validation** — an actual order retrieved end to end by a human

> Technical health and business correctness are different claims. Have someone
> from the application team confirm real functionality, not just HTTP 200.

## First 24 hours

- [ ] Survived a full daily traffic cycle including peak
- [ ] HPA scaled up and back down — confirms autoscaling works under *real* load
- [ ] Memory stable — a leak shows within hours, not minutes
- [ ] No alerts fired, or every one that did is explained
- [ ] A deploy performed and verified on the new platform
- [ ] **A rollback performed and verified** — before you need it in anger

## First week

- [ ] Survived a peak day
- [ ] Cost reviewed against forecast — [COST_CONTROL.md](COST_CONTROL.md)
- [ ] Alert thresholds tuned against real data (the first week always produces
      false positives)
- [ ] Runbooks corrected where reality disagreed with them
- [ ] On-call handover completed
- [ ] Old VMs still running, still untouched

## Decommission — only after two weeks

- [ ] A full business cycle survived, including month-end
- [ ] Sign-off from the application team
- [ ] Old VM configuration archived (not just deleted)
- [ ] DNS updated, old records removed
- [ ] Old firewall rules removed
- [ ] Old secrets revoked
- [ ] VMs stopped for a week **before** deletion

---

## What typically goes wrong

Ranked by how often, from real migrations of this shape:

1. **Secrets not migrated** — the app can't reach the database. *Prevention:*
   inventory every secret in discovery; fail fast with a specific error naming
   the missing key.
2. **Firewall written against the node CIDR, not the pod CIDR** — timeouts that
   look like application bugs. *Prevention:* rewrite every rule against the pod
   range in phase 2.
3. **Third party allowlisting the old egress IP** — payments fail at cutover.
   *Prevention:* ask every provider during discovery.
4. **No graceful shutdown** — 502s on every deploy. *Prevention:* preStop sleep
   plus readiness-off-then-drain, tested with a rolling update under load.
5. **Resource requests guessed** — pods `Pending`, or OOMKilled. *Prevention:*
   measure the old system, then set requests from data.
6. **DNS TTL never lowered** — rollback takes an hour. *Prevention:* lower it
   24 h ahead.
7. **No pre-migration baseline** — "is it slower?" becomes unanswerable.
   *Prevention:* record p50/p95/p99 and error rate before you start.
8. **Old VMs decommissioned too early** — no rollback path when a month-end
   problem appears in week three.

## Rollback triggers

Roll back — revert DNS — if any of these hold:

- Error rate above baseline for more than 5 minutes
- p95 latency more than 2× baseline
- Any data-integrity concern (**immediate, no discussion**)
- A dependency unreachable and not fixable within 15 minutes
- The team is not confident

**Rolling back a migration is not a failure.** It is the option you built
deliberately, and using it means the plan worked.

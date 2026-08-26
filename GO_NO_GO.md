# Go / No-Go Checklist

Complete this **before** cutting production traffic to GKE.

**How to use it:** every item gets a status, an owner, and **evidence** — a
command output, a screenshot, a link. "I'm pretty sure that's fine" is not
evidence. The point of this document is that six months later, someone can see
exactly what was verified and by whom.

| Status | Meaning |
|---|---|
| ✅ PASS | Verified, evidence attached |
| ❌ FAIL | Verified as broken — **blocks cutover** |
| ⚠️ RISK | Accepted with a named owner and a mitigation |
| ⬜ NOT CHECKED | **Treat as FAIL.** An unchecked item is not a passing item. |

**The gate:** any ❌ blocks cutover. Any ⚠️ needs an explicit, named person
accepting it in writing.

Automated evidence for a large portion of this:

```bash
./scripts/migration-validation.sh -n orders -v 2.4.17 \
  --gcp --project PROJECT --cluster CLUSTER --zone ZONE
```

---

## 1. Infrastructure

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 1.1 | Cluster status RUNNING | ⬜ | DevOps | `gcloud container clusters describe CLUSTER --zone ZONE --format='value(status)'` |
| 1.2 | All nodes Ready | ⬜ | DevOps | `kubectl get nodes` |
| 1.3 | No node pressure conditions | ⬜ | DevOps | `kubectl describe nodes \| grep -E 'MemoryPressure\|DiskPressure'` |
| 1.4 | Node pool autoscaling configured with a max | ⬜ | DevOps | `terraform output` |
| 1.5 | Cluster on a release channel (auto-upgrade) | ⬜ | DevOps | `gcloud container clusters describe ... --format='value(releaseChannel)'` |
| 1.6 | Terraform state stored safely, not only on a laptop | ⬜ | DevOps | backend config |

## 2. Networking

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 2.1 | VPC-native with both secondary ranges | ⬜ | DevOps | `gcloud container clusters describe ... --format='value(ipAllocationPolicy)'` |
| 2.2 | Secondary ranges sized for 3× current scale | ⬜ | DevOps | CIDR maths documented |
| 2.3 | Private Google Access enabled | ⬜ | DevOps | `gcloud compute networks subnets describe ...` |
| 2.4 | **Firewall rules rewritten against the POD CIDR** | ⬜ | Network | rule list |
| 2.5 | Connectivity to every dependency proven **from a pod** | ⬜ | DevOps | `kubectl exec` output |
| 2.6 | **New egress IP allowlisted by every third party** | ⬜ | App team | written confirmation from each provider |
| 2.7 | `master_authorized_networks` set (not empty) | ⬜ | Security | terraform.tfvars |

> **2.4 and 2.6 are the two that break cutovers.** A firewall written against the
> old VM subnet, and a payment provider still allowlisting the old NAT IP.

## 3. IAM and security

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 3.1 | Node SA is **not** the Compute Engine default | ⬜ | Security | `gcloud container clusters describe ... --format='value(nodeConfig.serviceAccount)'` |
| 3.2 | Node SA has only the 4 required roles | ⬜ | Security | `gcloud projects get-iam-policy` |
| 3.3 | Workload Identity enabled, **both binding halves** | ⬜ | Security | KSA annotation + GSA IAM policy |
| 3.4 | **No service-account JSON key exists** | ⬜ | Security | `gcloud iam service-accounts keys list --iam-account=SA` → user-managed keys: none |
| 3.5 | GitHub OIDC provider has an `attribute_condition` | ⬜ | Security | provider config |
| 3.6 | All secrets rotated from the old system | ⬜ | Security | rotation record |
| 3.7 | Secrets in Secret Manager, not in values files | ⬜ | Security | `helm get values` shows no secret |
| 3.8 | Containers non-root, no privilege escalation | ⬜ | Security | `migration-validation.sh` §5 |
| 3.9 | Every container has a memory limit | ⬜ | DevOps | `migration-validation.sh` §5 |
| 3.10 | Image scan clean of CRITICAL | ⬜ | Security | Trivy output |
| 3.11 | Repo scanned for secrets (**full history**) | ⬜ | Security | gitleaks output |

## 4. Application

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 4.1 | Correct version deployed and **verified at all layers** | ⬜ | DevOps | `./scripts/verify-version.sh` |
| 4.2 | All replicas available | ⬜ | DevOps | `kubectl get deploy` |
| 4.3 | Zero restarts since deploy | ⬜ | DevOps | `kubectl get pods` |
| 4.4 | **Pods spread across more than one node** | ⬜ | DevOps | `kubectl get pods -o wide` |
| 4.5 | All three probes configured and passing | ⬜ | DevOps | `kubectl describe pod` |
| 4.6 | Liveness does **not** check dependencies | ⬜ | DevOps | code review |
| 4.7 | **Graceful shutdown verified under load** | ⬜ | DevOps | rolling update with traffic, zero 502s |
| 4.8 | Resource requests derived from measurement | ⬜ | DevOps | old-system metrics |
| 4.9 | **Business functionality confirmed by the app team** | ⬜ | App team | signed-off test cases |

> **4.7 and 4.9 are the two most often skipped.** Nobody tests a rolling update
> *under traffic* until it drops requests in production. And nobody asks a human
> to retrieve a real order — HTTP 200 is not the same as correct.

## 5. Image and registry

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 5.1 | Artifact Registry in the same region as the cluster | ⬜ | DevOps | `terraform output` |
| 5.2 | **Immutable tags enabled** | ⬜ | DevOps | repo config |
| 5.3 | Image digest recorded and pinned in the deploy | ⬜ | DevOps | pipeline log |
| 5.4 | Node SA can pull (repo-scoped reader) | ⬜ | DevOps | pods running |
| 5.5 | Cleanup policy configured | ⬜ | DevOps | repo config |

## 6. Data

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 6.1 | Database reachable **from a pod** | ⬜ | DBA | `kubectl exec` connection test |
| 6.2 | Connection pool sized for `maxReplicas`, not `replicas` | ⬜ | DBA | **`maxReplicas × pool_size` must not exceed the DB's `max_connections`** |
| 6.3 | Backups verified by an actual restore | ⬜ | DBA | restore test record |
| 6.4 | Migrations are backward compatible | ⬜ | App team | review |
| 6.5 | Rollback tested **with the current schema** | ⬜ | DBA | test record |

> **6.2 is a real trap.** With `maxReplicas: 5` and a pool of 20, a traffic spike
> opens 100 connections. If the database allows 100 total and something else is
> connected, the HPA scaling up *causes* the outage it was meant to prevent.
>
> **6.4 decides whether rollback is even possible.** If the new version ran a
> migration the old version can't read, rolling back the app without the schema
> makes things worse.

## 7. Observability

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 7.1 | Logs reaching Cloud Logging, fields parsed | ⬜ | DevOps | Logs Explorer query |
| 7.2 | Dashboard imported and populating | ⬜ | DevOps | screenshot |
| 7.3 | **Alerts attached to a notification channel** | ⬜ | DevOps | `gcloud alpha monitoring policies list` |
| 7.4 | **Alert delivery tested** — someone received one | ⬜ | DevOps | test alert |
| 7.5 | `kubectl top` works (metrics-server) | ⬜ | DevOps | command output |
| 7.6 | **Pre-migration baselines recorded** | ⬜ | DevOps | p50/p95/p99, error rate, req/s at peak |

> **7.4:** an alert policy with no working channel is decoration. Fire a test one
> and confirm a human received it.
>
> **7.6:** without baselines, "is it slower than before?" cannot be answered, and
> every post-migration performance discussion becomes opinion.

## 8. CI/CD

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 8.1 | Pipeline runs green end to end | ⬜ | DevOps | Actions run |
| 8.2 | Pipeline authenticates via OIDC, no key | ⬜ | Security | workflow file |
| 8.3 | **Pipeline includes a version-verification gate** | ⬜ | DevOps | workflow file |
| 8.4 | Smoke test hits **business** endpoints with ≥20 requests | ⬜ | DevOps | workflow file |
| 8.5 | `--wait --atomic` on the Helm step | ⬜ | DevOps | workflow file |

> **8.4:** one request against a 30% failure rate passes 70% of the time. Sample
> size matters.

## 9. Autoscaling and resilience

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 9.1 | HPA showing real metrics, not `<unknown>` | ⬜ | DevOps | `kubectl get hpa` |
| 9.2 | **HPA scale-up verified under load** | ⬜ | DevOps | `./scripts/load-test.sh` |
| 9.3 | PDB exists with `ALLOWED DISRUPTIONS ≥ 1` | ⬜ | DevOps | `kubectl get pdb` |
| 9.4 | **Node drain completes without hanging** | ⬜ | DevOps | drain output |
| 9.5 | Pod deletion causes no user-visible errors | ⬜ | DevOps | delete a pod under load |

> **9.4 catches an over-strict PDB before it stalls a cluster upgrade at 02:00.**

## 10. Rollback

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 10.1 | **More than one Helm revision exists** | ⬜ | DevOps | `helm history` — with one revision there is nothing to roll back to |
| 10.2 | **Rollback rehearsed and timed** | ⬜ | DevOps | timing record |
| 10.3 | Previous image still present in the registry | ⬜ | DevOps | `gcloud artifacts docker images list` |
| 10.4 | **DNS TTL lowered to ≤60 s at least 24 h ago** | ⬜ | Network | `dig orders.company.com` |
| 10.5 | Old VMs still running and capable of serving | ⬜ | Infra | health check against the old VIP |
| 10.6 | Rollback runbook reviewed by whoever is on call | ⬜ | On-call | sign-off |

> **10.4:** a 3600 s TTL means a DNS rollback takes an hour. That is not a
> rollback.
>
> **10.5:** the old VMs are the real rollback plan. Do not decommission for two
> weeks.

## 11. DNS and TLS

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 11.1 | Certificate valid, **>30 days to expiry** | ⬜ | Network | cert details |
| 11.2 | Certificate covers every hostname served | ⬜ | Network | SAN list |
| 11.3 | DNS change procedure documented and access confirmed | ⬜ | Network | runbook |
| 11.4 | Weighted routing available for a staged cutover | ⬜ | Network | DNS provider config |

## 12. Performance

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 12.1 | p95 latency within 20% of baseline | ⬜ | DevOps | comparison |
| 12.2 | Error rate at or below baseline | ⬜ | DevOps | comparison |
| 12.3 | Peak-load test passed | ⬜ | DevOps | load test results |
| 12.4 | No memory growth over a sustained run | ⬜ | DevOps | memory graph over ≥4 h |

## 13. Cost

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 13.1 | **Budget alert configured** | ⬜ | DevOps | `gcloud billing budgets list` |
| 13.2 | Forecast reviewed and approved | ⬜ | Manager | forecast |
| 13.3 | No unintended billable resources | ⬜ | DevOps | `./scripts/destroy-gcp.sh --verify-only` |
| 13.4 | Resources labelled for cost attribution | ⬜ | DevOps | labels |

## 14. Support readiness

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 14.1 | On-call rota covers the cutover window **and the following night** | ⬜ | Manager | rota |
| 14.2 | Runbooks reviewed by the people who will use them | ⬜ | On-call | sign-off |
| 14.3 | **Everyone on call has cluster access, tested today** | ⬜ | DevOps | `kubectl get pods` by each person |
| 14.4 | Escalation path documented with names and numbers | ⬜ | Manager | contact list |
| 14.5 | Incident channel created | ⬜ | Manager | channel link |
| 14.6 | Stakeholders told the cutover window | ⬜ | Manager | comms |

> **14.3:** "I'll get access if something breaks" is how a 5-minute incident
> becomes a 45-minute one. Have every on-call engineer run a real command today.

## 15. Communication

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 15.1 | Cutover plan circulated | ⬜ | Manager | doc link |
| 15.2 | Maintenance window announced | ⬜ | Manager | comms |
| 15.3 | Rollback decision-maker named | ⬜ | Manager | **one named person, not a committee** |
| 15.4 | Status update cadence agreed | ⬜ | Manager | plan |

> **15.3:** during an incident, "should we roll back?" must have one owner. A
> committee debating it is how 5 minutes of impact becomes 40.

## 16. Documentation

| # | Check | Status | Owner | Evidence |
|---|---|---|---|---|
| 16.1 | Architecture documented | ⬜ | DevOps | [ARCHITECTURE.md](ARCHITECTURE.md) |
| 16.2 | Runbooks complete | ⬜ | DevOps | this repo |
| 16.3 | Known issues and risks listed | ⬜ | DevOps | below |
| 16.4 | Post-migration support plan agreed | ⬜ | Manager | plan |

---

## Decision

| | |
|---|---|
| **Date / time** | |
| **Decision** | ☐ GO  ☐ NO-GO  ☐ GO WITH CONDITIONS |
| **Decision maker** | |
| **PASS / FAIL / RISK counts** | |
| **Accepted risks** (each with a named owner) | |
| **Conditions** | |
| **Rollback decision-maker during the window** | |
| **Next review** | |

**Signatures**

| Role | Name | Signature | Date |
|---|---|---|---|
| DevOps lead | | | |
| Application owner | | | |
| Security | | | |
| Manager | | | |

---

## A note on how to run this

The temptation is to treat this as paperwork and tick it through in twenty
minutes. Don't.

The items most likely to be waved through are exactly the ones that cause
incidents: **6.2** (connection pool vs `maxReplicas`), **7.4** (nobody tested
alert delivery), **10.4** (DNS TTL), **14.3** (on-call access), and **4.7**
(graceful shutdown under load).

Each of those takes ten minutes to verify properly and costs hours if it's wrong.

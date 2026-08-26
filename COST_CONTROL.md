# Cost Control

> **Read this before running `terraform apply`.**
>
> Nothing in this repository creates a billable resource on its own. Every
> expensive option is behind a flag that defaults to OFF. But once you apply,
> **GKE nodes bill by the hour whether or not a single request reaches them.**

---

## The one thing to internalise

**"Free tier" and "free credits" are not the same thing, and neither means free.**

| | What it is | What happens when it runs out |
|---|---|---|
| **Free tier** | A permanent monthly allowance on specific SKUs (e.g. one zonal GKE cluster's management fee). Renews every month. | You start paying the normal rate. |
| **Free trial credits** | A one-time $300 / 90-day grant for new accounts. | **Billing stops and resources are suspended, then deleted.** |
| **Committed spend** | Neither. | n/a |

Free credits are *consumed* by an idle cluster exactly as fast as by a busy one.
A node pool left running over a two-week holiday burns roughly the same credit
whether you touched it or not.

---

## What this project creates, and what each costs

Prices are `us-central1`, on-demand USD, and are indicative — **always confirm
against the [GCP pricing calculator](https://cloud.google.com/products/calculator)**,
because pricing changes and varies by region.

### Billed continuously

| Resource | Default | Rate | ~Monthly | Notes |
|---|---|---|---|---|
| **GKE cluster management** | 1 zonal cluster | $0.10/hr | **$72** | GKE free tier gives **one** zonal or Autopilot cluster per *billing account* a $74.40/month credit, which cancels this out. A **second** cluster is billed in full. |
| **Node VM** | 1× `e2-small` **SPOT** | ~$0.0057/hr | **~$4** | On-demand instead of Spot: ~$12–13/month. This is your main lever. |
| **Boot disk** | 30 GB `pd-standard` | $0.04/GB-mo | **~$1.20** | `pd-ssd` is roughly 4× this. |
| **VPC, subnet, routes, firewall** | always | — | **$0** | Networking primitives are free to exist. |
| **Artifact Registry storage** | ~200 MB | $0.10/GB-mo beyond 0.5 GB free | **$0** | Free until you accumulate images. Cleanup policies keep it flat. |
| **IAM, service accounts, WIF** | always | — | **$0** | No charge, ever. Use it properly. |
| **Cloud Logging** | SYSTEM + WORKLOADS | free to 50 GiB/project/mo, then $0.50/GiB | **$0** at lab volume | A chatty app at `DEBUG` can blow through 50 GiB surprisingly fast. |

**Realistic total at defaults: ~$5–7/month while running**, assuming the GKE
free-tier credit applies and nothing else in the project competes for it.

### Off by default — turn on deliberately

| Resource | Flag | Cost | Why it's off |
|---|---|---|---|
| **Cloud NAT** | `enable_cloud_nat` | ~$32/mo + $0.045/GB | Not needed. Private Google Access already reaches Artifact Registry and Cloud Logging for free. Only required for egress to the *public* internet. |
| **HTTP(S) Load Balancer** (Ingress) | `enable_http_load_balancing`, `ingress.enabled` | ~$18/mo per forwarding rule, **billed at zero traffic** | `kubectl port-forward` proves the same thing for $0. |
| **VPC Flow Logs** | `enable_flow_logs` | Cloud Logging ingestion per GB | Useful during a network investigation, expensive as a default. |
| **Managed Prometheus** | `enable_managed_prometheus` | Free to 100k samples, then per-sample | Needed for the app dashboards. Turn on when you want them; turn off after. |
| **Filestore CSI** | hard-coded `false` | **from ~$200/mo** | Never enable casually. |

### Things that are free and worth knowing are free

Terraform state (local), Workload Identity Federation, GitHub Actions on a
public repo, all IAM, VPC networking, the entire local `kind` stack.

---

## The full-cost trap list

These are the ways people actually get surprised, in rough order of frequency.

1. **A `LoadBalancer` Service or Ingress you forgot.**
   Terraform did not create it, so `terraform destroy` does not remove it. The
   forwarding rule keeps billing after the cluster is gone. `destroy-gcp.sh`
   checks for this explicitly.
2. **Orphaned persistent disks.** Deleting a cluster does not always delete
   disks created by PVCs. A detached disk bills at full rate forever.
3. **Reserved static IPs.** A *reserved but unattached* external IP is billed;
   an attached one is not. Deleting the LB without releasing the IP leaves a
   small permanent charge.
4. **A second cluster.** The GKE free-tier credit covers exactly one. Spinning
   up a "quick test cluster" doubles your bill to ~$72/month.
5. **Regional instead of zonal.** A regional cluster runs your node pool in
   *three* zones. `node_count = 1` becomes 3 VMs. Pass a zone, not a region.
6. **Log volume.** `LOG_LEVEL=DEBUG` on a service under load can exceed the
   50 GiB free allowance in days.
7. **Cross-region image pulls.** If Artifact Registry is in a different region
   from the cluster, every pull is billed as inter-region egress. This repo
   forces `location = var.region` for exactly this reason.
8. **Leaving it running.** The most common one by far. It is not dramatic —
   just $0.20/day, quietly, for months.

---

## How to keep the bill at zero

### Best: don't use GCP at all

Everything in this repository except the GCP-specific layers runs locally:

```bash
./scripts/local-up.sh
```

The failure lab, HPA scaling, rollback drills, version verification, probes,
PDB behaviour, troubleshooting — all of it works on `kind`, for **$0**, with no
account and no risk. Use GCP only when you specifically want to practise
`gcloud`, Workload Identity, Artifact Registry, or Cloud Monitoring.

### Set a budget alert before you apply anything

Do this **first**, not after. It takes two minutes.

```bash
gcloud billing budgets create \
  --billing-account=YOUR_BILLING_ACCOUNT_ID \
  --display-name="gke-lab-budget" \
  --budget-amount=10USD \
  --threshold-rule=percent=50 \
  --threshold-rule=percent=90 \
  --threshold-rule=percent=100
```

> A budget **alerts**; it does **not** cap spend. Nothing in GCP hard-stops
> billing by default. If you want a true kill switch, wire the budget's Pub/Sub
> topic to a Cloud Function that unlinks billing — or just use the destroy
> script.

### Destroy when you finish, every time

```bash
./scripts/destroy-gcp.sh
```

This runs `terraform destroy` **and then independently re-inventories the
project** with `gcloud`, because Terraform only knows about resources in its
state file. Anything created by a Kubernetes controller is invisible to it.

Check without deleting:

```bash
./scripts/destroy-gcp.sh --verify-only
```

### The nuclear option

The only way to *guarantee* a zero bill:

```bash
gcloud billing projects unlink YOUR_PROJECT_ID
```

Everything stops. Relink when you next want to work.

---

## Cheaper if you need to run longer

| Change | Saving | Trade-off |
|---|---|---|
| `use_spot_vms = true` (default) | 60–91% off compute | Node can be reclaimed with 30s notice |
| `e2-micro` instead of `e2-small` | ~50% off compute | 1 GB RAM — GKE system pods barely fit; expect scheduling pain |
| `min_node_count = 0` + cluster autoscaler | Node cost only when pods exist | Cold-start delay; the cluster fee still applies |
| **Scale to zero when idle** | Node cost → ~0 | See below |
| `disk_size_gb = 20` | ~$0.40/mo | Close to the practical floor for the GKE node image |
| Delete the cluster nightly | ~$2/mo | ~5 min to recreate; `terraform apply` makes it painless |

**Scale to zero without destroying the cluster** — useful if you want to keep
the cluster config but stop paying for compute overnight:

```bash
gcloud container clusters resize CLUSTER_NAME \
  --node-pool POOL_NAME --num-nodes 0 --zone ZONE --quiet
```

The **cluster management fee still applies** (offset by the free-tier credit for
one cluster); only the node VMs stop. Resize back to 1 to resume.

---

## Monitoring what you're spending

```bash
# Is billing even enabled on this project?
gcloud billing projects describe PROJECT_ID

# Which billing account, and is it open?
gcloud billing accounts list

# Everything currently billable, in one sweep
./scripts/destroy-gcp.sh --verify-only
```

In the console:
- **Billing → Reports** — group by SKU to see exactly which line item is growing.
- **Billing → Budgets & alerts** — set it before you need it.
- **Billing → Cost breakdown** — shows free-tier credits applied.

Billing data lags by up to **24 hours**. A cluster you deleted this morning may
still appear in today's report. Do not panic, and do not delete things twice.

Every resource this project creates carries `environment` and `managed-by`
labels, so you can filter cost reports by them.

---

## A note on this specific project

At the time this repository was built, the target GCP project's billing account
reported `open: false` — a closed billing account, meaning **no resources could
be created at all**. That is why `VALIDATION_REPORT.md` marks every GKE-specific
claim as `REQUIRES REAL GCP VALIDATION` rather than tested.

If you hit `billingEnabled: false`, no amount of Terraform debugging will help
— fix the billing account in the Cloud Console first.

---

## Pre-apply checklist

- [ ] Budget alert created on the billing account
- [ ] `terraform.tfvars` points at the intended project — check twice
- [ ] `authorized_networks` set to your own IP, not left empty
- [ ] All four cost flags confirmed `false`
- [ ] `zone` is a **zone** (`us-central1-a`), not a region
- [ ] `max_node_count` is small (default 3)
- [ ] You have read the `terraform plan` output, specifically for
      `google_container_node_pool`, `google_compute_router_nat`, and any
      forwarding rule
- [ ] A calendar reminder to run `./scripts/destroy-gcp.sh`

## Post-work checklist

- [ ] `./scripts/destroy-gcp.sh` run and reported **CLEAN**
- [ ] `gcloud container clusters list` returns nothing
- [ ] `gcloud compute instances list` returns nothing
- [ ] `gcloud compute forwarding-rules list` returns nothing
- [ ] `gcloud compute disks list` returns nothing
- [ ] `gcloud compute addresses list` shows nothing `RESERVED`
- [ ] Billing report checked ~24h later to confirm spend actually stopped

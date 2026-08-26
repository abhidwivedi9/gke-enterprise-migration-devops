# Operations Runbook

Day-to-day operation of `orders-api` on GKE. What you do when someone asks for
something.

| Someone says… | Go to |
|---|---|
| "Deploy version 2.4.17" | [REAL_DEVOPS_SUPPORT_WORKFLOW.md](REAL_DEVOPS_SUPPORT_WORKFLOW.md) |
| "Is production healthy?" | [§ Daily health check](#daily-health-check) |
| "Pods are restarting" | [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| "Users are getting 500s" | [docs/INCIDENT_HTTP_500.md](docs/INCIDENT_HTTP_500.md) |
| "What version is running?" | [§ Version check](#version-check) |
| "Roll it back" | [ROLLBACK_RUNBOOK.md](ROLLBACK_RUNBOOK.md) |
| "Is HPA working?" | [docs/AUTOSCALING.md](docs/AUTOSCALING.md) |
| "We need more capacity" | [§ Scaling](#scaling) |
| "Rotate this secret" | [§ Secret rotation](#secret-rotation) |
| "The cluster needs upgrading" | [§ Cluster upgrade](#cluster-upgrade) |
| "What is this costing?" | [COST_CONTROL.md](COST_CONTROL.md) |

---

## Start of shift

```bash
gcloud container clusters get-credentials CLUSTER --zone ZONE --project PROJECT
kubectl config current-context          # confirm before anything else

./scripts/health-check.sh -n orders
./monitoring/ops-dashboard.sh -n orders
```

Then check:
- Any alerts fired overnight? Each one either explained or investigated.
- Any deploys since your last shift? `helm history orders-api -n orders`
- Any pods with restarts? A restart at 03:00 that self-healed still deserves
  30 seconds of attention.

> **Confirm your kubectl context every session.** Not once a week — every
> session. It is the cheapest habit in this document.

---

## Daily health check

```bash
./scripts/health-check.sh -n orders
```

Seven checks: API reachable, nodes Ready, replicas available, endpoints present,
restart count, application endpoints, and **the real request success rate**.

That last one is the important one. Probes returning 200 proves the process is
alive; it does not prove the API works. The gap between them is
[the 500s incident](docs/INCIDENT_HTTP_500.md).

**Weekly, additionally:**

```bash
kubectl top nodes                                    # capacity trend
kubectl get events -A --field-selector type=Warning | tail -30
helm history orders-api -n orders                    # what shipped this week
./scripts/destroy-gcp.sh --verify-only               # anything unexpected billing?
```

---

## Version check

Fastest, in order of effort:

```bash
# 1. Label column - instant, no port-forward
kubectl get pods -n orders -L app.kubernetes.io/version

# 2. What the Deployment asks for
kubectl get deployment orders-api -n orders \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# 3. Ground truth - ask the running process, sampled
kubectl port-forward -n orders svc/orders-api 8080:80 &
for i in $(seq 1 10); do curl -s localhost:8080/version | jq -r .application_version; done | sort | uniq -c

# 4. All nine layers
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17
```

> Sample repeatedly at step 3. A single request proves one pod. If step 3 prints
> more than one distinct version, you have a mixed fleet.

---

## Deploying

Full 17-step procedure: [REAL_DEVOPS_SUPPORT_WORKFLOW.md](REAL_DEVOPS_SUPPORT_WORKFLOW.md)

```bash
# Preferred - auditable, reproducible
gh workflow run deploy-dev.yml -f version=2.4.17
gh run watch

# Direct
./scripts/deploy.sh 2.4.17 --env dev --registry REGION-docker.pkg.dev/PROJECT/orders

# Preview without changing anything
./scripts/deploy.sh 2.4.17 --env dev --dry-run
```

**Before every deploy:**
1. Confirm the version exists (git tag **and** registry)
2. Record the current revision — that's your rollback target
3. Confirm your kubectl context

**After every deploy:** verify the version, check the real success rate, and
watch the dashboard for 10–15 minutes. Memory leaks and connection-pool
exhaustion only appear after the new version has served real traffic.

---

## Scaling

### Temporary — handle a spike now

```bash
kubectl scale deployment/orders-api --replicas=5 -n orders
```
> ⚠️ **The HPA will undo this** at its next evaluation. It's a stopgap for the
> next few minutes, not a change.

### Permanent

```bash
helm upgrade orders-api ./helm/application \
  -f helm/application/values.yaml -f helm/application/values-dev.yaml \
  -n orders --reuse-values \
  --set autoscaling.minReplicas=3 --set autoscaling.maxReplicas=10
```

> **Before raising `maxReplicas`, check the database connection pool.**
> `maxReplicas × pool_size` must stay below the database's `max_connections`.
> Otherwise the HPA scaling up *causes* the outage it was meant to prevent.

### Cluster capacity

```bash
# COSTS MONEY
gcloud container clusters resize CLUSTER --node-pool POOL --num-nodes 2 --zone ZONE
```
> **When:** pods are `Pending` with `Insufficient cpu` and requests are already
> right-sized. Check `kubectl describe nodes | grep -A8 "Allocated resources"`
> first — that shows **requests**, and a cluster idling at 5% real CPU can be
> 100% requested.

---

## Restarting

```bash
# One bad pod - the Deployment recreates it. Safe.
kubectl delete pod POD -n orders

# All pods, rolling, no image change - the correct way
kubectl rollout restart deployment/orders-api -n orders
kubectl rollout status deployment/orders-api -n orders
```

> **`rollout restart` is how you pick up a changed Secret.** Values consumed via
> `env`/`envFrom` are injected at container start and never updated, so editing a
> Secret changes nothing until pods restart.
>
> **Never `kubectl delete deployment`** to "restart" something. It deletes every
> pod at once — a full outage — and `rollout restart` does it safely.

---

## Secret rotation

```bash
# 1. New version in Secret Manager
echo -n 'NEW_VALUE' | gcloud secrets versions add orders-db-dsn --data-file=-

# 2. Or, for a Kubernetes Secret
kubectl create secret generic orders-api-secrets -n orders \
  --from-literal=ORDERS_DB_DSN='NEW_VALUE' \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Pods must restart to pick it up
kubectl rollout restart deployment/orders-api -n orders
kubectl rollout status deployment/orders-api -n orders

# 4. Verify
kubectl exec POD -n orders -- env | grep ORDERS_DB   # confirm it changed
./scripts/health-check.sh -n orders                   # confirm it still works
```

> **Order matters if the credential is for a live dependency.** Create the new
> database user *before* rotating, so both old and new credentials work during
> the rollout. Rotating first and restarting second means every pod fails until
> the rollout completes.

---

## Cluster upgrade

```bash
gcloud container get-server-config --zone ZONE          # what versions are available
gcloud container clusters upgrade CLUSTER --master --zone ZONE     # control plane FIRST
gcloud container clusters upgrade CLUSTER --node-pool POOL --zone ZONE
```

**Before upgrading nodes, verify a drain works:**

```bash
kubectl get pdb -n orders          # ALLOWED DISRUPTIONS must be >= 1
kubectl drain NODE --ignore-daemonsets --delete-emptydir-data --dry-run=client
```

> **A node upgrade drains each node in turn, so an over-strict PDB stalls it
> indefinitely.** `ALLOWED DISRUPTIONS: 0` means the upgrade will hang. Find that
> out now, not at 02:00 mid-upgrade.
>
> **Control plane before nodes, always.** Kubernetes supports a control plane up
> to two minor versions *ahead* of its nodes, never behind.

With `auto_upgrade = true` and a release channel (this project's default), GKE
handles this. Your job is making sure the PDB and probes let it happen without
disruption.

---

## Node maintenance

```bash
kubectl cordon NODE                                             # no new pods
kubectl drain NODE --ignore-daemonsets --delete-emptydir-data   # evict
# ... maintenance ...
kubectl uncordon NODE
```

> If the drain hangs: `kubectl get pdb -A`. That's the cause roughly every time.
>
> `--ignore-daemonsets` is required — DaemonSet pods are recreated on the node
> immediately and would otherwise block forever.

---

## Investigating an incident

```bash
# 1. PRESERVE EVIDENCE FIRST - fixing destroys it
./scripts/collect-logs.sh -n orders

# 2. Triage
./scripts/health-check.sh -n orders
./scripts/verify-pods.sh -n orders

# 3. What changed?
helm history orders-api -n orders
kubectl get events -n orders --sort-by=.lastTimestamp | tail -20
```

> **Step 1 before step 2.** Events expire after ~1 hour, `--previous` logs hold
> only the last terminated container, and deleting a pod destroys its logs. The
> moment you start fixing, you start destroying the record of what happened.

→ [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

---

## Weekly and monthly

**Weekly**
- [ ] Review alerts that fired — tune anything noisy. An alert nobody trusts is
      worse than no alert.
- [ ] Check resource usage against requests; right-size if consistently wrong.
- [ ] Review cost against forecast.
- [ ] Confirm backups (if a data tier exists).

**Monthly**
- [ ] **Rollback drill** — practise on a non-production namespace.
- [ ] Review and apply security patches (base image, dependencies).
- [ ] Verify the cluster is on a supported version.
- [ ] Audit IAM: `gcloud iam service-accounts keys list` — any user-managed keys
      should not exist.
- [ ] Run through a failure-lab scenario to keep the muscle memory.

---

## Escalate when

- Users are affected and you have no hypothesis after 15 minutes
- The fix is irreversible
- Data loss or corruption is possible
- It spans teams — database, network, a third party
- You're about to do something you haven't done before, in production

**When in doubt, roll back first.** A rollback is reversible; a bad fix under
pressure often isn't.

---

## Things to be careful with

| Command | Why |
|---|---|
| `kubectl delete namespace` | Deletes **everything** in it, including Secrets and PVCs. No undo. |
| `kubectl delete deployment` | Full outage. Use `rollout restart` instead. |
| `kubectl delete pod --force --grace-period=0` | Removes the API object while the container may still run. Split-brain risk for StatefulSets. |
| `terraform destroy` | Use `./scripts/destroy-gcp.sh`, which verifies afterwards. |
| `kubectl apply` without `kubectl diff` | You don't know what you're changing. |
| `helm upgrade` without `--atomic` | A failed rollout stays half-broken. |
| Any write command without checking your context | You may be in the wrong cluster. |

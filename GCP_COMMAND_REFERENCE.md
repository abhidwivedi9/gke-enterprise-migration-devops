# GCP / gcloud Command Reference

Organised by **when you'd run it**. Every section says why, not just what.

---

## Before anything — which project am I in?

```bash
gcloud config list
gcloud config get-value project
gcloud projects list
gcloud config set project PROJECT_ID
gcloud auth list
gcloud auth login
gcloud auth application-default login     # for Terraform and client libraries
```

> **When:** every time before a write operation, and first thing after switching
> machines. `gcloud config set project` on the wrong project is how test
> resources end up in production.
>
> **`gcloud auth login` vs `application-default login`** are different
> credentials. The first authenticates the `gcloud` CLI; the second writes
> Application Default Credentials that Terraform and client libraries use.
> Terraform failing with "could not find default credentials" while `gcloud`
> works fine means you ran the first and not the second.

---

## Billing — check this FIRST when nothing works

```bash
gcloud billing projects describe PROJECT_ID     # billingEnabled: true?
gcloud billing accounts list                    # OPEN: True?
gcloud billing accounts describe ACCOUNT_ID
```

> **When:** before your first `terraform apply` in a project, and any time
> resource creation fails with something that looks like a permissions error.
>
> **A closed billing account blocks everything**, and the error messages don't
> say so clearly. This exact condition — `billingEnabled: false` on a project
> whose billing account showed `open: false` — is what prevented real GCP
> validation of this repository.

```bash
gcloud billing projects unlink PROJECT_ID       # the guaranteed-zero-bill button
gcloud billing projects link PROJECT_ID --billing-account=ACCOUNT_ID
```

```bash
gcloud billing budgets create \
  --billing-account=ACCOUNT_ID \
  --display-name="gke-lab" --budget-amount=10USD \
  --threshold-rule=percent=50 --threshold-rule=percent=90
```
> **When: before creating any billable resource, not after.** A budget *alerts*;
> it does not cap spend. Nothing in GCP hard-stops billing by default.

---

## APIs

```bash
gcloud services list --enabled
gcloud services list --available | grep container
gcloud services enable container.googleapis.com
```
> **When:** you see *"Service X has not been used in project Y before or it is
> disabled."* Enabling is free and takes about a minute to propagate — if the
> next command still fails, wait 60 seconds before assuming something else.

---

## GKE — daily

```bash
gcloud container clusters list
gcloud container clusters describe CLUSTER --zone ZONE
gcloud container clusters get-credentials CLUSTER --zone ZONE --project PROJECT
```

> **`get-credentials` is the first command of every GKE session.** It writes the
> cluster into your kubeconfig and switches context. Without it, `kubectl` talks
> to whatever cluster you last used — possibly a different environment.
>
> **`--zone` for a zonal cluster, `--region` for a regional one.** Using the
> wrong flag gives a "not found" error that looks like the cluster is missing.

Fields worth pulling out individually:
```bash
gcloud container clusters describe CLUSTER --zone ZONE --format='value(status)'
gcloud container clusters describe CLUSTER --zone ZONE --format='value(currentMasterVersion)'
gcloud container clusters describe CLUSTER --zone ZONE --format='value(nodeConfig.serviceAccount)'
gcloud container clusters describe CLUSTER --zone ZONE --format='value(workloadIdentityConfig)'
gcloud container clusters describe CLUSTER --zone ZONE --format='value(privateClusterConfig)'
```
> **`nodeConfig.serviceAccount`** — if this says `default`, your nodes are
> running as the Compute Engine default service account, which holds
> project-wide Editor. That's the highest-value GKE security finding there is.

---

## GKE — node pools and scaling

```bash
gcloud container node-pools list --cluster CLUSTER --zone ZONE
gcloud container node-pools describe POOL --cluster CLUSTER --zone ZONE

# COSTS MONEY
gcloud container clusters resize CLUSTER --node-pool POOL --num-nodes 2 --zone ZONE

# SAVES MONEY - stop paying for compute without destroying the cluster
gcloud container clusters resize CLUSTER --node-pool POOL --num-nodes 0 --zone ZONE --quiet
```

> **Scaling to zero** is the overnight cost lever: node VMs stop billing, the
> cluster management fee continues (offset by the free-tier credit for one
> cluster). Resize back to 1 to resume.

```bash
gcloud container operations list --zone ZONE          # what is GKE doing right now?
gcloud container operations describe OP_ID --zone ZONE
```
> **When:** the cluster is in `RECONCILING` and you want to know why, or an
> upgrade seems stuck.

---

## GKE — upgrades

```bash
gcloud container get-server-config --zone ZONE          # available versions
gcloud container clusters upgrade CLUSTER --master --zone ZONE
gcloud container clusters upgrade CLUSTER --node-pool POOL --zone ZONE
```
> **Control plane first, then nodes.** Kubernetes supports a control plane at
> most two minor versions ahead of its nodes, never behind. Upgrading nodes past
> the control plane is unsupported.
>
> A node upgrade drains each node in turn — so it will **hang on an over-strict
> PodDisruptionBudget**. Test a drain before you need an upgrade.

---

## Artifact Registry

```bash
gcloud artifacts repositories list
gcloud artifacts repositories describe REPO --location=REGION
gcloud auth configure-docker REGION-docker.pkg.dev

gcloud artifacts docker images list REGION-docker.pkg.dev/PROJECT/REPO
gcloud artifacts docker images list REGION-docker.pkg.dev/PROJECT/REPO --include-tags

# THE version-verification command
gcloud artifacts docker images describe \
  REGION-docker.pkg.dev/PROJECT/REPO/orders-api:2.4.17 \
  --format='value(image_summary.digest)'
```

> **`images describe`** settles the "but I definitely pushed it" conversation in
> ten seconds: either the tag resolves to a digest or it doesn't.
>
> **The digest it returns is the artifact identity** — the value every running
> pod's `imageID` must match. → [docs/VERSION_VERIFICATION.md](docs/VERSION_VERIFICATION.md)

```bash
gcloud artifacts repositories get-iam-policy REPO --location=REGION
gcloud artifacts repositories add-iam-policy-binding REPO --location=REGION \
  --member="serviceAccount:NODE_SA" --role="roles/artifactregistry.reader"
```
> **When:** `ImagePullBackOff` with `denied: Permission ... downloadArtifacts`.
> Grant on the **repository**, not the project — nodes should be able to pull
> this image, not every image.

---

## IAM

```bash
gcloud iam service-accounts list
gcloud iam service-accounts describe SA_EMAIL
gcloud projects get-iam-policy PROJECT_ID
gcloud projects get-iam-policy PROJECT_ID \
  --flatten="bindings[].members" --filter="bindings.members:SA_EMAIL" \
  --format="value(bindings.role)"
```
> **The last one is the audit query:** exactly what can this identity do? Run it
> on the node SA and on the CI SA during a security review.

```bash
gcloud iam service-accounts keys list --iam-account=SA_EMAIL
```
> **Run this as a security check.** Any `USER_MANAGED` key is a long-lived
> credential that never expires and works from anywhere. This project creates
> none — the expected output is only the Google-managed keys.

```bash
# Workload Identity - BOTH halves must exist and match exactly
gcloud iam service-accounts add-iam-policy-binding GSA_EMAIL \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:PROJECT.svc.id.goog[NAMESPACE/KSA_NAME]"

kubectl annotate sa KSA_NAME -n NAMESPACE \
  iam.gke.io/gcp-service-account=GSA_EMAIL
```
> **When:** a pod gets 403 from a Google API. Check both halves and confirm the
> namespace and KSA name match character for character — the error message names
> neither side of the mismatch.

```bash
gcloud iam workload-identity-pools list --location=global
gcloud iam workload-identity-pools providers describe PROVIDER \
  --workload-identity-pool=POOL --location=global \
  --format='value(attributeCondition)'
```
> **Check `attributeCondition` is not empty.** Without it, *any* GitHub
> repository can mint a token your provider accepts.

---

## Secret Manager

```bash
gcloud secrets list
gcloud secrets create orders-db-dsn --replication-policy=automatic
echo -n 'postgresql://...' | gcloud secrets versions add orders-db-dsn --data-file=-
gcloud secrets versions access latest --secret=orders-db-dsn
gcloud secrets add-iam-policy-binding orders-db-dsn \
  --member="serviceAccount:APP_SA" --role="roles/secretmanager.secretAccessor"
```
> ⚠️ `versions access` prints the secret to your terminal — and into your shell
> history and any session recording. Use it to verify existence, not routinely.

---

## Cloud Logging

```bash
gcloud logging read 'resource.type="k8s_container"' --limit 20 --format json

gcloud logging read \
  'resource.type="k8s_container" AND resource.labels.namespace_name="orders" AND jsonPayload.status>=500' \
  --limit 20 --format='table(timestamp, jsonPayload.pod, jsonPayload.path, jsonPayload.status)'

gcloud logging read 'jsonPayload.request_id="REQUEST_ID"' --format json
gcloud alpha logging tail 'resource.labels.namespace_name="orders"'
```
> **When:** an incident older than ~1 hour, when `kubectl logs` and events are
> gone. Cloud Logging retains 30 days and includes pods that no longer exist.

```bash
# The audit log - "who changed this cluster, and when?"
gcloud logging read \
  'logName="projects/PROJECT/logs/cloudaudit.googleapis.com%2Factivity"
   AND protoPayload.serviceName="container.googleapis.com"' \
  --limit 20 --format='table(timestamp, protoPayload.authenticationInfo.principalEmail, protoPayload.methodName)'
```
> **When:** something changed and nobody admits to changing it. This is the
> answer.

```bash
gcloud logging metrics create orders_api_5xx \
  --description="orders-api 5xx" \
  --log-filter='resource.type="k8s_container"
                resource.labels.namespace_name="orders"
                jsonPayload.status>=500'
```
> **When:** you want to alert on something with no native metric. Turning a log
> query into a metric is the most useful trick in Cloud Logging — and it's how
> you alert on 5xx without paying for Managed Prometheus.

---

## Cloud Monitoring

```bash
gcloud monitoring dashboards list
gcloud monitoring dashboards create --config-from-file=monitoring/dashboards/gke-operations-dashboard.json
gcloud alpha monitoring policies list
gcloud alpha monitoring policies create --policy-from-file=monitoring/alerts/high-5xx-rate.json
gcloud alpha monitoring channels list
gcloud alpha monitoring channels create --display-name="oncall" --type=email \
  --channel-labels=email_address=you@example.com
```
> **An alert policy with no notification channel fires into the void.** Create
> the channel, attach it, then send a test alert and confirm a human received it.

---

## Compute — mostly for cost checks

```bash
gcloud compute instances list
gcloud compute disks list                  # detached disks still bill
gcloud compute addresses list              # RESERVED but not IN_USE still bills
gcloud compute forwarding-rules list       # ~$18/mo each, billed at zero traffic
gcloud compute routers list                # Cloud NAT, ~$32/mo
gcloud compute networks subnets describe SUBNET --region REGION
```

> **Run all of these before you finish for the day.** They're exactly what
> `./scripts/destroy-gcp.sh --verify-only` checks, and they're the resources that
> keep billing after a cluster is deleted — because Terraform never knew about
> the ones a Kubernetes controller created.

---

## Teardown

```bash
./scripts/destroy-gcp.sh                # terraform destroy + independent verification
./scripts/destroy-gcp.sh --verify-only  # check without deleting
```

Manual, if needed:
```bash
gcloud container clusters delete CLUSTER --zone ZONE
gcloud compute forwarding-rules delete NAME --region REGION
gcloud compute addresses delete NAME --region REGION
gcloud compute disks delete NAME --zone ZONE
gcloud artifacts repositories delete REPO --location=REGION
```

> **Delete the Kubernetes Ingress/LoadBalancer Services FIRST**, then wait for
> the controller to remove the GCP load balancer, then delete the cluster.
> Deleting the cluster first orphans the load balancer, which keeps billing and
> which Terraform cannot see.

→ [COST_CONTROL.md](COST_CONTROL.md)

---

## Output formatting

```bash
--format='value(FIELD)'                       # one value, script-friendly
--format='table(a, b, c)'
--format=json | jq '.'
--filter='status=RUNNING'
--limit=10
```

> **`--format='value(...)'` is what you want in scripts** — no headers, no
> decoration, nothing to parse.

```bash
gcloud container clusters describe CLUSTER --zone ZONE --format=json | jq 'keys'
```
> **When:** you don't know the field path. Dump JSON, find the key, then use
> `--format='value(that.key)'`.

---

## The 10 to know cold

```bash
gcloud config get-value project                                       # 1. where am I?
gcloud billing projects describe PROJECT                              # 2. can I create anything?
gcloud container clusters list                                        # 3. what clusters exist?
gcloud container clusters get-credentials CLUSTER --zone ZONE         # 4. connect kubectl
gcloud artifacts docker images describe IMAGE:TAG                     # 5. does the image exist?
gcloud logging read 'jsonPayload.status>=500' --limit 20              # 6. what is failing?
gcloud projects get-iam-policy PROJECT --flatten=... --filter=...     # 7. what can this SA do?
gcloud iam service-accounts keys list --iam-account=SA                # 8. any long-lived keys?
gcloud compute forwarding-rules list                                  # 9. am I paying for an LB?
./scripts/destroy-gcp.sh --verify-only                                # 10. what is still billing?
```

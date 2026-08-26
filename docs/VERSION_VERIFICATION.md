# Version Verification

## Why a deployment can say SUCCESS while the wrong version is running

This is the single most important idea in this repository.

Every layer of a Kubernetes deployment reports on **its own** job, and every one
of them can report success truthfully while the application serves different
code than you intended.

| Layer | What it actually asserts | What it does **not** assert |
|---|---|---|
| GitHub Actions ✅ | Every step exited 0 | That the right image was built, or that it reached the cluster |
| `docker push` ✅ | Bytes were uploaded | That the tag still points at those bytes |
| `helm upgrade` ✅ | The API server accepted the manifests | That any pod started — without `--wait`, Helm never looks |
| Helm `deployed` ✅ | The release record was written | That the pods match it |
| `rollout status` ✅ | The new ReplicaSet reached its desired count | That the ReplicaSet references the image you meant |
| Deployment `3/3` ✅ | Three pods pass readiness | Which code those pods are running |
| Pod `Running` ✅ | A container is alive | Which image layer it actually resolved |

Every green tick is honest. None of them answers *"is version 2.4.17 serving
requests right now?"*

Only one thing does: **asking the running process.**

---

## The nine failure modes

### 1. The tag was mutable and got overwritten

Someone re-ran a build and pushed `:2.4.17` again from different code. Your pods
started before the overwrite; new pods start after. The tag is identical, the
code is not.

```bash
# The tag now resolves to a different digest than when your pods started
gcloud artifacts docker images describe REGISTRY/orders-api:2.4.17 \
  --format='value(image_summary.digest)'
kubectl get pods -n orders -o jsonpath='{.items[*].status.containerStatuses[0].imageID}'
```

**Fix:** immutable tags — Terraform sets `immutable_tags = true`. Once set,
`:2.4.17` can never be repointed. This eliminates the entire class.

---

### 2. `imagePullPolicy: IfNotPresent` + a cached layer

The node already had *something* tagged `:2.4.17`. With `IfNotPresent`, the
kubelet never contacts the registry. Your freshly pushed image is never pulled.

`IfNotPresent` is only safe **because** our tags are immutable. With mutable
tags you'd need `Always` — and pay a registry round-trip on every pod start.

---

### 3. Only Helm metadata changed

`appVersion` in `Chart.yaml` is a **label**. Bumping it changes what `helm list`
reports and nothing about what runs. If the image reference didn't change, no
new pod template exists, so no rollout happens at all.

This is failure-lab scenario 10, and it's the most embarrassing one: every
human-readable signal says 2.4.18.

---

### 4. The rollout is half finished

Three pods: two new, one old. The Service load-balances across all of them.

```
curl /version → 2.4.17
curl /version → 2.4.17
curl /version → 2.4.16   ← one request in three
```

This is the worst mode, because it presents as **intermittent** — the bug is
"fixed" two times out of three, and averaged dashboards hide it completely. A
single `curl` gives you a false green.

**This is why `verify-version.sh` samples eight times.**

---

### 5. CI pushed to a different registry than the Deployment pulls from

`us-central1-docker.pkg.dev/proj-a/orders` vs `gcr.io/proj-b/orders`. Both
commands succeed. They're simply not talking about the same artifact.

---

### 6. Someone patched the Deployment by hand

`kubectl set image` or `kubectl edit` changes the live object. Helm's stored
manifest still describes the old state. The cluster is right, Helm is wrong —
and the *next* `helm upgrade` silently reverts the manual change.

```bash
helm get manifest orders-api -n orders | grep image:
kubectl get deployment orders-api -n orders -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Same problem with `kubectl rollout undo`: it fixes the Deployment and leaves
Helm's state stale.

---

### 7. A ConfigMap changed but no pod restarted

Editing a ConfigMap consumed via `env`/`envFrom` does **nothing** to running
pods — those values are injected at container start and never updated. The
config "deployed" successfully and every pod still uses the old value.

**Fix:** the `checksum/config` annotation pattern this chart uses. Hashing the
rendered ConfigMap into the pod template means a config change alters the
template, which forces a rolling update.

---

### 8. Multiple ReplicaSets are still serving

A stuck rollout leaves old and new ReplicaSets both with running pods.

```bash
kubectl get rs -n orders -o wide     # more than one with DESIRED > 0
```

---

### 9. The build didn't bake the version in

The image is correct but `/version` reports `0.0.0-dev`, because `--build-arg`
wasn't passed or the Dockerfile `ARG`/`ENV` chain is broken. Now you have no way
to verify anything.

**Fix:** `build.sh` and the CI pipeline both assert the baked-in version
immediately after building, and fail if it's wrong.

---

## The nine layers, and how to check each

```
  1. Git commit          git rev-parse HEAD
  2. Image tag           docker inspect / image labels
  3. Registry digest     gcloud artifacts docker images describe
  4. Helm release        helm list -n NS
  5. Deployment spec     kubectl get deploy -o jsonpath='{...containers[0].image}'
  6. ReplicaSet          kubectl get rs -n NS
  7. Pod spec            .spec.containers[0].image        ← REQUESTED
  8. Running container   .status.containerStatuses[0].imageID  ← ACTUAL
  9. Application         curl /version                    ← GROUND TRUTH
```

**Layers 7 and 8 are different fields and they can disagree.** `spec.image` is
what you asked for; `status.imageID` is the digest the kubelet actually resolved
and started. When a mutable tag has been overwritten, only `imageID` is true.

Run all nine at once:

```bash
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17 \
  --registry us-central1-docker.pkg.dev/PROJECT/orders
```

Real output from a healthy deployment on a live cluster:

```
[4] Deployment: what image is in the pod template (the DESIRED state)?
          image: orders-api:2.4.17
     PASS  Deployment references the expected version
          replicas: desired=2 available=2 updated=2
     PASS  every replica is on the current template

[5] Pods: reconcile requested image vs the digest actually running
          orders-api-cdf4ff75b-2kwjd  [Running]
              spec  : orders-api:2.4.17
              running: sha256:afc19f2833cea286e2dc28b58124c7cc89450f872608e917ce77374750d64fbd
          orders-api-cdf4ff75b-p8hr9  [Running]
              spec  : orders-api:2.4.17
              running: sha256:afc19f2833cea286e2dc28b58124c7cc89450f872608e917ce77374750d64fbd
     PASS  all pods run one identical digest
     PASS  0 restarts across all pods

[6] Application /version — ask the running process directly
          reported version : 2.4.17
          reported commit  : 000000000000
     PASS  THE RUNNING APPLICATION REPORTS 2.4.17
     PASS  8/8 sampled requests served 2.4.17
```

---

## Doing it manually

```bash
# 3. What does the tag resolve to in the registry?
gcloud artifacts docker images describe \
  REGION-docker.pkg.dev/PROJECT/orders/orders-api:2.4.17 \
  --format='value(image_summary.digest)'

# 5. What does the Deployment ask for?
kubectl get deployment orders-api -n orders \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# 7 + 8. Requested vs actually running, per pod
kubectl get pods -n orders -l app.kubernetes.io/instance=orders-api \
  -o custom-columns='POD:.metadata.name,SPEC:.spec.containers[0].image,RUNNING:.status.containerStatuses[0].imageID'

# 9. The only answer that counts
kubectl port-forward -n orders svc/orders-api 8080:80 &
for i in $(seq 1 10); do
  curl -s localhost:8080/version | jq -r .application_version
done | sort | uniq -c
```

That last command is the single most useful one-liner in this document. If it
prints more than one distinct version, you have a mixed fleet.

---

## Making it impossible

Ordered by how much they actually help:

### 1. Immutable tags
```hcl
docker_config { immutable_tags = true }
```
A tag becomes a permanent pointer. Eliminates failure modes 1 and 2 outright.

### 2. Deploy by digest
```bash
helm upgrade ... --set image.digest=sha256:9c8b7a...
```
Rendered as `repository@sha256:...`. Byte-for-byte deterministic; there is
nothing left to be ambiguous about. The CI pipeline does this.

### 3. Bake identity into the image at build time
```dockerfile
ARG APP_VERSION
ARG GIT_COMMIT
ENV APP_VERSION=${APP_VERSION} GIT_COMMIT=${GIT_COMMIT}
```
Then expose it at `/version`. Without this, verification is impossible — you'd
be asking Kubernetes about Kubernetes.

### 4. Verify in the pipeline, and fail on mismatch
The deploy job runs `verify-version.sh` as a gate. A pipeline that reports
SUCCESS without checking what's actually serving is reporting on itself, not on
production.

### 5. Sample multiple times
One request proves one pod. Eight requests across a 2-replica Service is
reasonable confidence; on a 20-replica deployment, sample proportionally more.

---

## The interview answer

> **"GitHub Actions says the deployment succeeded, but users report the old
> version is still running. How do you find out what happened?"**

Walk the layers in order, and name the specific field at each:

1. **Registry** — `gcloud artifacts docker images describe`. Does the tag exist,
   and what digest does it resolve to *now*?
2. **Helm** — `helm list`. Status `deployed`? Which revision? What `appVersion`?
3. **Deployment** — `.spec.template.spec.containers[0].image`. Does it reference
   the version I expect?
4. **Rollout completeness** — is `updatedReplicas == replicas`? If not, some
   traffic is still hitting old pods right now.
5. **Pods** — compare `.spec.containers[0].image` against
   `.status.containerStatuses[0].imageID`. **`imageID` is the ground truth at the
   Kubernetes layer** — it's the resolved digest, not the requested tag.
6. **The application** — `curl /version`, sampled several times to catch a mixed
   fleet.

Then name the likely causes: a mutable tag overwritten; `IfNotPresent` reusing a
cached layer; only Helm metadata changed; a half-finished rollout; a
registry-path mismatch; or a manual `kubectl` patch that Helm doesn't know about.

Finish with the prevention: **immutable tags, digest-pinned deploys, a
build-time-baked `/version`, and a pipeline gate that fails when they
disagree.**

That answer demonstrates you've actually operated a system rather than read
about one — because the field names, and the distinction between `spec.image`
and `status.imageID`, are things you only learn by having been burned.

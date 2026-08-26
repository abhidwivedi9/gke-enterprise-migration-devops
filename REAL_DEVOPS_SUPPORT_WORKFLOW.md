# The Real DevOps Support Workflow

> **Ticket ORD-4471** — *"Please deploy orders-api version 2.4.17 to GKE dev.
> Contains the fix for the duplicate-order bug. Needs to be live before the
> 14:00 demo."* — filed by the application team, 11:20.

This is the job. Not architecture diagrams — this. Someone asks for a version,
and you make it live, prove it's live, and are able to undo it.

Seventeen steps. The whole thing takes about 20 minutes, and roughly 12 of those
are verification. That ratio is the point: **the deploy is easy; being certain
is the work.**

---

## Step 1 — Check the requested version actually exists

Before touching anything, establish that the thing you were asked to deploy is
real. Roughly one ticket in five names a version that was never built, or a
version number the developer *intended* rather than one that exists.

```bash
git fetch --all --tags
git tag -l 'v2.4.*' --sort=-v:refname | head
```

```
v2.4.17
v2.4.16
v2.4.15
```

**If the tag doesn't exist, stop and reply to the ticket.** Do not guess, do not
deploy `main`, do not deploy 2.4.16 "because it's close". The most expensive
deployments start with an assumption at step 1.

---

## Step 2 — Check the Git commit

Find out exactly what code you're about to ship.

```bash
git show v2.4.17 --stat --no-patch
git log v2.4.16..v2.4.17 --oneline
```

```
commit 7f3a9c2e1b4d8a6f5c3e2d1a9b8c7f6e5d4c3b2a
Author: ...
Date:   Wed Aug 26 09:14:00 2026

    fix: dedupe order IDs on retry (ORD-4470)

 app/src/main.py       | 14 ++++++++---
 app/tests/test_main.py|  8 ++++++
```

**What you're looking for:**
- Does the diff match what the ticket describes? A "one-line bug fix" touching
  40 files is a conversation, not a deploy.
- Are there migrations, config changes, or new required env vars? Those need
  handling *before* the rollout, not during it.
- Is there a test for the fix? If not, ask.

Record the commit SHA. Everything downstream is checked against it.

---

## Step 3 — Check the image exists

```bash
gcloud artifacts docker images describe \
  us-central1-docker.pkg.dev/PROJECT/orders/orders-api:2.4.17 \
  --format='value(image_summary.digest, image_summary.fully_qualified_digest)'
```

```
sha256:9c8b7a6f5e4d3c2b1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b
```

**This digest is the artifact identity.** Write it down. Every later check
compares against it.

If it 404s: CI either didn't run, didn't push, or pushed somewhere else. Check
the pipeline before assuming the registry is broken.

---

## Step 4 — Confirm image and commit agree

The image claims to be built from a commit. Verify that claim rather than
trusting it.

```bash
gcloud artifacts docker images describe \
  us-central1-docker.pkg.dev/PROJECT/orders/orders-api:2.4.17 \
  --format='value(image_summary.labels)'
```

Look for `org.opencontainers.image.revision` matching the SHA from step 2.

> **Why bother?** Because a tag can be applied to an image built from a
> different commit — by a re-run, a manual `docker tag`, or a race in CI. If
> these disagree, you're about to deploy something nobody reviewed.

---

## Step 5 — Check the current state before you change it

You cannot know whether a deploy worked if you don't know what "before" looked
like.

```bash
gcloud container clusters get-credentials orders-api-dev-gke \
  --zone us-central1-a --project PROJECT

kubectl config current-context          # CONFIRM THIS. Every time.
./scripts/health-check.sh -n orders
helm list -n orders
helm history orders-api -n orders
```

```
NAME        NAMESPACE  REVISION  STATUS    CHART            APP VERSION
orders-api  orders     7         deployed  orders-api-1.0.0 2.4.16
```

**Record: current version 2.4.16, revision 7.** That's your rollback target, and
you want it now — not at 14:05 while someone is asking why the demo is broken.

> **Deploying to the wrong cluster** because `kubectl` context was left pointing
> somewhere else is a genuinely common production incident. `deploy.sh` refuses
> to run a non-local deploy against a `kind-*` context for this reason.

---

## Step 6 — Deploy

Two routes. Prefer the pipeline: it's auditable, reproducible, and someone else
can see what happened.

**Route A — the pipeline (preferred)**
```bash
gh workflow run deploy-dev.yml -f version=2.4.17
gh run watch
```

**Route B — direct, when the pipeline is unavailable**
```bash
./scripts/deploy.sh 2.4.17 --env dev \
  --registry us-central1-docker.pkg.dev/PROJECT/orders
```

Underneath, the flags that matter:

```bash
helm upgrade --install orders-api ./helm/application \
  -f helm/application/values.yaml -f helm/application/values-dev.yaml \
  -n orders \
  --set image.tag=2.4.17 \
  --set image.digest=sha256:9c8b7a...  \
  --wait --atomic --timeout 10m
```

- `--wait` — block until pods are actually Ready. Without it, `helm upgrade`
  returns 0 the moment the API server accepts the YAML.
- `--atomic` — if the wait fails, roll back automatically rather than leaving a
  half-broken release.
- `--set image.digest` — pin the exact artifact. This is what makes the deploy
  deterministic.

---

## Step 7 — Monitor the rollout as it happens

```bash
kubectl rollout status deployment/orders-api -n orders --timeout=5m
```

In a second terminal, watch pods turn over:

```bash
kubectl get pods -n orders -w
```

```
orders-api-7d9f8c-abc   1/1   Running       0     8m    ← old
orders-api-7d9f8c-def   1/1   Running       0     8m    ← old
orders-api-9a1b2c-ghi   0/1   Pending       0     0s    ← new
orders-api-9a1b2c-ghi   0/1   ContainerCreating
orders-api-9a1b2c-ghi   0/1   Running       0     3s    ← starting
orders-api-9a1b2c-ghi   1/1   Running       0     12s   ← Ready
orders-api-7d9f8c-abc   1/1   Terminating   0     8m    ← old drains
```

**Healthy rollout:** new pods reach `1/1` *before* old ones terminate
(`maxUnavailable: 0`), and each takes roughly the same time to become Ready.

**Warning signs:** a new pod sitting `Pending` (no capacity), taking far longer
than usual to become Ready (probe or dependency problem), or restarting at all.

---

## Step 8 — Check the pods

```bash
kubectl get pods -n orders -o wide
./scripts/verify-pods.sh -n orders
```

Confirm: all `1/1`, `RESTARTS 0`, and — worth noticing — spread across more than
one node. If all replicas landed on one node, a single node failure is still a
full outage and the migration hasn't bought you what you think.

---

## Step 9 — Check the events

```bash
kubectl get events -n orders --sort-by=.lastTimestamp | tail -20
```

Events are where Kubernetes explains itself. `Scheduled`, `Pulled`, `Created`,
`Started` is the happy path. Anything `Warning` deserves reading even if the
pods came up — a `BackOff` that resolved on retry is a latent problem.

> Events expire after ~1 hour. If you need them later, capture them now with
> `./scripts/collect-logs.sh`.

---

## Step 10 — Check the logs

```bash
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=50
```

```json
{"severity":"INFO","message":"orders-api started: version=2.4.17 commit=7f3a9c2e1b4d env=dev",...}
```

**Look for:** the startup line reporting the version you expect, no ERROR or
WARNING at boot, and no stack traces.

**Then check the previous container** — if any pod restarted even once during
the rollout, `--previous` tells you why.

---

## Step 11 — Verify the running image

Now the version checks begin. This is where a deploy that "succeeded" gets
caught.

```bash
kubectl get pods -n orders -l app.kubernetes.io/instance=orders-api \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
```

Two different fields, and the difference matters:

- `.spec.containers[0].image` — what was **requested**
- `.status.containerStatuses[0].imageID` — the digest actually **resolved and
  running**

When a mutable tag has been overwritten, these disagree, and only `imageID`
tells the truth. Compare it against the digest from step 3.

---

## Step 12 — Verify `/version`

The only genuine ground truth: ask the running process.

```bash
kubectl port-forward -n orders svc/orders-api 8080:80 &
curl -s localhost:8080/version | jq
```

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

The commit must match step 2. The version must match the ticket.

**Sample it several times.** With a partially completed rollout, different
requests land on different pods and a single `curl` gives you a false green:

```bash
for i in $(seq 1 10); do curl -s localhost:8080/version | jq -r .application_version; done | sort | uniq -c
```

```
     10 2.4.17          ← what you want
```

```
      6 2.4.17          ← what you do NOT want: mixed fleet
      4 2.4.16
```

**Or do steps 11–12 in one command:**
```bash
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17 \
  --registry us-central1-docker.pkg.dev/PROJECT/orders
```

---

## Step 13 — Verify health

Probes returning 200 proves the process is alive. It does **not** prove the API
works.

```bash
curl -s localhost:8080/health
curl -s localhost:8080/ready
curl -s localhost:8080/api/orders | jq        # the BUSINESS endpoint

# Real success rate over a sample
for i in $(seq 1 30); do
  curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/api/orders
done | sort | uniq -c
```

```
     30 200
```

Anything other than 30/30 is a problem, even if every pod is Ready. That gap —
green probes, failing requests — is exactly the incident in
[docs/INCIDENT_HTTP_500.md](docs/INCIDENT_HTTP_500.md).

**If the ticket describes a specific fix, test the fix.** For ORD-4471 that
means retrying an order and confirming no duplicate ID. Deploying the fix isn't
the same as the bug being gone.

---

## Step 14 — Verify replicas

```bash
kubectl get deployment orders-api -n orders
```

```
NAME         READY   UP-TO-DATE   AVAILABLE   AGE
orders-api   2/2     2            2           14d
```

All three numbers must agree. `UP-TO-DATE` below `READY` means some pods are
still on the old template — the rollout isn't finished, whatever `rollout
status` said.

---

## Step 15 — Verify the HPA

```bash
kubectl get hpa orders-api -n orders
```

```
NAME         REFERENCE               TARGETS       MINPODS  MAXPODS  REPLICAS
orders-api   Deployment/orders-api   cpu: 12%/70%  2        5        2
```

`TARGETS` showing a real percentage means the HPA can see metrics. `<unknown>`
means it will never scale, and you'll discover that during the first traffic
spike instead of now. → [docs/AUTOSCALING.md](docs/AUTOSCALING.md)

---

## Step 16 — Check the dashboard

Give it 5–10 minutes of real traffic, then look at:

- **Request rate** — back to normal levels? A drop can mean traffic isn't
  reaching the new pods.
- **Error rate** — this is the one that matters. Compare against the pre-deploy
  baseline, not against zero.
- **p95/p99 latency** — a new version that's 3× slower is a failed deploy even
  if it returns 200.
- **CPU / memory** — a step change means resource requests may need revisiting.
- **Restarts** — must stay flat.

→ [monitoring/DASHBOARD_GUIDE.md](monitoring/DASHBOARD_GUIDE.md)

Watch for **10–15 minutes** before declaring success. Some failures — memory
leaks, connection-pool exhaustion, cache-related errors — only appear after the
new version has served real traffic for a while.

---

## Step 17 — Confirm and communicate

Run the full validation once more, and record the evidence:

```bash
./scripts/migration-validation.sh -n orders -v 2.4.17
```

Then close the ticket with something a colleague can act on at 2am:

> **ORD-4471 — deployed.**
>
> - **Version:** 2.4.17 (was 2.4.16)
> - **Commit:** `7f3a9c2e1b4d`
> - **Image digest:** `sha256:9c8b7a6f5e4d…`
> - **Deployed:** 2026-08-26 11:42 UTC · Helm revision 8
> - **Verified:** `/version` reports 2.4.17 across 10/10 sampled requests;
>   2/2 replicas available; 0 restarts; error rate 0% over 30 requests;
>   p95 latency 42 ms (baseline 40 ms)
> - **Rollback:** `helm rollback orders-api 7 -n orders --wait` → returns 2.4.16
>
> Monitoring for the next hour.

**Include the rollback command.** If this goes wrong at 02:00 and you're asleep,
whoever is on call should not have to reconstruct it.

---

## The compressed version

Once these are muscle memory:

```bash
# 1. Verify the request is real
git tag -l 'v2.4.17' && gcloud artifacts docker images describe REGISTRY/orders-api:2.4.17

# 2. Know your escape route
helm history orders-api -n orders

# 3. Deploy
./scripts/deploy.sh 2.4.17 --env dev --registry REGISTRY

# 4. Prove it (deploy.sh does this, but know what it's doing)
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17 --registry REGISTRY
./scripts/health-check.sh -n orders

# 5. If it's bad
./scripts/rollback.sh -n orders
```

---

## What to do when it goes wrong

| At step | Symptom | Go to |
|---|---|---|
| 1–4 | Tag or image missing | Reply to the ticket. Don't improvise. |
| 6 | `helm upgrade` fails | `--atomic` rolled back. [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| 7 | Rollout stalls | [TROUBLESHOOTING.md §1–4](TROUBLESHOOTING.md) |
| 8 | Pods not Ready | [TROUBLESHOOTING.md §5](TROUBLESHOOTING.md#5-readiness-probe-failure) |
| 11–12 | Wrong version | [docs/VERSION_VERIFICATION.md](docs/VERSION_VERIFICATION.md) |
| 13 | 500s with green probes | [docs/INCIDENT_HTTP_500.md](docs/INCIDENT_HTTP_500.md) |
| 16 | Errors or latency up | [ROLLBACK_RUNBOOK.md](ROLLBACK_RUNBOOK.md) |

**The rule:** if users are affected, roll back first and investigate afterwards.
Rolling back in 3 minutes and debugging calmly beats debugging in production for
40 minutes while the error rate climbs.

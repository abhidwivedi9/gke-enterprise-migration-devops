# 7-Day Study Plan

Seven days to being genuinely comfortable operating this system — not reading
about it.

**The rule that makes this work: do, then read.** Every day you break something
first and diagnose it before opening the explanation. Reading the answer first
converts an exercise into a blog post, and you will not remember it under
pressure.

Budget roughly **2–3 hours a day**. Everything runs locally for $0.

```bash
./scripts/local-up.sh        # once, on day 1 — takes about 10 minutes
```

---

## Day 1 — The system, end to end

**Goal:** know what exists and be able to deploy it from nothing.

**Do (90 min)**
```bash
./scripts/local-up.sh
kubectl get all -n orders
./scripts/health-check.sh -n orders
./monitoring/ops-dashboard.sh -n orders
```

Then read the manifests the chart actually produced — not the templates:
```bash
helm get manifest orders-api -n orders | less
```

Ask yourself, for each object: why does this exist? What breaks without it?

Deploy a change and watch it roll:
```bash
kubectl get pods -n orders -w      # second terminal
helm upgrade orders-api ./helm/application \
  -f helm/application/values.yaml -f helm/application/values-local.yaml \
  -n orders --set config.LOG_LEVEL=DEBUG --wait
```

**Read (45 min)** — [README](../README.md), [ARCHITECTURE.md](../ARCHITECTURE.md)

**By tonight you should be able to say:** what each Kubernetes object in this
namespace does, and what would break if you deleted it.

---

## Day 2 — Version verification

**Goal:** internalise the single most important idea here — a deploy can succeed
at every layer and still run the wrong code.

**Do (90 min)**
```bash
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17
```

Read the script itself. Understand what each of the nine layers proves.

Then break it deliberately:
```bash
./failure-lab/run.sh start 10        # Helm claims 2.4.18, pods serve 2.4.17
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.18
```

Watch *which layer* catches the lie. Then run each check by hand:
```bash
kubectl get deployment orders-api -n orders -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl get pods -n orders -o custom-columns='POD:.metadata.name,SPEC:.spec.containers[0].image,RUNNING:.status.containerStatuses[0].imageID'
for i in $(seq 1 10); do curl -s localhost:8080/version | jq -r .application_version; done | sort | uniq -c
```

**Read (45 min)** — [docs/VERSION_VERIFICATION.md](VERSION_VERIFICATION.md)

**Be able to explain out loud:** the difference between
`.spec.containers[0].image` and `.status.containerStatuses[0].imageID`, and name
five ways the wrong version ends up running.

---

## Day 3 — Pod troubleshooting

**Goal:** diagnose any broken pod without looking anything up.

**Do (2 hours)** — scenarios 1–8, one at a time. For each: inject, diagnose,
*then* read.

```bash
for s in 01 02 03 04 05 06 07 08; do echo "--- $s ---"; done   # work through these
./failure-lab/run.sh start 01
# diagnose it. Give yourself 10 minutes before opening anything.
./failure-lab/run.sh explain 01
./failure-lab/run.sh reset
```

**Time yourself.** By scenario 8 you should be diagnosing in under three minutes.

The four commands to reach for without thinking:
```bash
kubectl get pods -n orders
kubectl describe pod POD -n orders
kubectl logs POD -n orders --previous
kubectl get events -n orders --sort-by=.lastTimestamp
```

**Read (30 min)** — [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) §1–8

**Be able to explain:** exit 137 vs 143 vs an application exit code, and why
`--previous` matters.

---

## Day 4 — Deploy, rollback, and the incident

**Goal:** run the full support workflow, and handle a bad release.

**Do (2 hours)**

The real deploy workflow, all 17 steps:
```bash
./scripts/build.sh 2.4.18 --kind orders-lab --allow-dirty
./scripts/deploy.sh 2.4.18 --env local
```

Then the incident that matters most:
```bash
./failure-lab/run.sh start 15         # 30% 500s, all probes green
./scripts/health-check.sh -n orders   # see the real success rate
```

Walk the request path yourself before rolling back — endpoints, pods, logs
grouped by pod:
```bash
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=500 \
  | jq -r 'select(.status>=500) | .pod' | sort | uniq -c
```

**Then time your rollback:**
```bash
time ./scripts/rollback.sh -n orders
```
Confirm recovery with a real sample, not a single request.

**Read (45 min)** — [REAL_DEVOPS_SUPPORT_WORKFLOW.md](../REAL_DEVOPS_SUPPORT_WORKFLOW.md),
[ROLLBACK_RUNBOOK.md](../ROLLBACK_RUNBOOK.md), [docs/INCIDENT_HTTP_500.md](INCIDENT_HTTP_500.md)

**Be able to explain:** why every probe stayed green while 30% of users got
errors, and why you roll back before root-causing.

---

## Day 5 — Autoscaling, resilience, and the rest of the lab

**Goal:** understand what keeps the service up when things move.

**Do (2 hours)**
```bash
./scripts/load-test.sh -n orders -d 180 -c 20     # watch it scale
kubectl describe hpa orders-api -n orders          # read the Conditions
```

Then break autoscaling and resilience:
```bash
./failure-lab/run.sh start 13     # HPA never scales
./failure-lab/run.sh start 11     # PDB blocks a node drain
./failure-lab/run.sh start 14     # Service has no endpoints
```

For 11, actually try the drain and watch it hang:
```bash
kubectl drain $(kubectl get pods -n orders -o jsonpath='{.items[0].spec.nodeName}') \
  --ignore-daemonsets --delete-emptydir-data --timeout=60s
```

Then test graceful shutdown under traffic — delete a pod while curling in a loop
and confirm you see zero errors.

**Read (45 min)** — [docs/AUTOSCALING.md](AUTOSCALING.md),
[monitoring/DASHBOARD_GUIDE.md](../monitoring/DASHBOARD_GUIDE.md)

**Be able to explain:** why `TARGETS: <unknown>` has exactly two causes and how
`kubectl top` distinguishes them; and what a PDB does and does not protect.

---

## Day 6 — GCP, Terraform, security, cost

**Goal:** be able to discuss the cloud layer credibly, whether or not you deploy
it.

**Do (2 hours)**
```bash
cd terraform/environments/dev
terraform init -backend=false
terraform validate
terraform fmt -check -recursive ../..
```

Read the modules and, for each resource, answer: what does it cost, and what
breaks if it's misconfigured?

Then trace the two identity flows end to end in the code:
- **CI → GCP:** `terraform/modules/iam/main.tf` → `.github/workflows/deploy-dev.yml`
- **Pod → Google APIs:** the IAM binding → the KSA annotation in
  `templates/serviceaccount.yaml`

If you have a working GCP account:
```bash
gcloud billing projects describe PROJECT_ID     # check FIRST
terraform plan                                   # read it, do not apply yet
```

**Read (60 min)** — [SECURITY.md](../SECURITY.md), [COST_CONTROL.md](../COST_CONTROL.md),
[MIGRATION_PLAN.md](../MIGRATION_PLAN.md)

**Be able to explain:** why there's no service-account key anywhere; the two
halves of a Workload Identity binding; and the five biggest cost levers on GKE.

---

## Day 7 — Interview readiness

**Goal:** be able to talk about all of this without notes.

**Do (2 hours)**

1. **Say the 5-minute pitch out loud, three times.** Not read — spoken. Record
   yourself once; it's uncomfortable and it works.

2. **Work the ten priority questions** from
   [docs/INTERVIEW_QUESTIONS.md](INTERVIEW_QUESTIONS.md): 1, 3, 6, 19, 21, 32,
   33, 87, 98, 100. Cover the answer, speak yours, compare.

3. **Rehearse the three stories** — the 30%-error rollback with real numbers, the
   exit-code correction, and the awk bug in the dashboard. Specifics are what
   distinguish someone who operated a system from someone who read about one.

4. **Practise the honesty answer:** *"Did you actually deploy this to GCP?"*
   Have that one crisp. Volunteering what you haven't proven reads as seniority.

5. **Final run-through** — bring the whole stack up from nothing and verify it,
   to confirm the muscle memory is real:
   ```bash
   kind delete cluster --name orders-lab
   ./scripts/local-up.sh
   ./scripts/health-check.sh -n orders
   ```

**Read (45 min)** — [INTERVIEW_GUIDE.md](../INTERVIEW_GUIDE.md) in full.

---

## Keeping it

The knowledge decays if you don't use it. Ongoing:

- **Weekly:** one failure-lab scenario, cold. Rotate through all 15 over a
  quarter.
- **Monthly:** a rollback drill, timed. Bring the stack up from scratch.
- **Before any interview:** re-read [INTERVIEW_GUIDE.md](../INTERVIEW_GUIDE.md)
  and speak the 5-minute pitch twice.

---

## If you only have one day

In priority order:

1. `./scripts/local-up.sh` and `./scripts/health-check.sh` — see it work (20 min)
2. Failure-lab **scenario 15** and roll back — the incident that matters most
   (40 min)
3. `./scripts/verify-version.sh` and
   [VERSION_VERIFICATION.md](VERSION_VERIFICATION.md) — the central idea (40 min)
4. Failure-lab **01, 05, 14** — the three most common pod failures (40 min)
5. The 5-minute pitch from [INTERVIEW_GUIDE.md](../INTERVIEW_GUIDE.md), spoken
   twice (20 min)

Those five give you the highest-value 80% in about three hours.

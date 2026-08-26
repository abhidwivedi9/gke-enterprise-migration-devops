# Rollback Runbook

> **Rollback is not a failure. It is the correct first response to a bad
> release.**
>
> Rolling back in 3 minutes and investigating calmly beats debugging in
> production for 40 minutes while users are affected. Stop the bleeding first.

---

## Scenario: version 2.4.17 is causing production errors

**14:03** — Alert fires: `HighErrorRate — 5xx rate 28% over 5 minutes`.
2.4.17 was deployed at 13:51.

---

## DETECT

You find out one of three ways, in descending order of how good your monitoring is:

1. **An alert fires** — the system told you. This is what you want.
2. **A colleague asks "is something wrong with orders?"** — your alerting has a gap.
3. **A customer complains** — your alerting has a hole.

**Quantify before you act.** "Users are getting errors" is not actionable;
"28% of `/api/orders` requests have returned 500 since 13:52" is.

```bash
./scripts/health-check.sh -n orders
```
```
[7] Business endpoint success rate (20 requests)
 FAIL  14/20 succeeded (70%) - USERS ARE SEEING ERRORS
```

```bash
# Error rate from the app's own metrics
kubectl port-forward -n orders svc/orders-api 8080:80 &
curl -s localhost:8080/metrics | grep 'http_requests_total.*status="5'

# Recent errors, with request IDs for correlation
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=200 \
  | grep '"status":5'
```

**Answer three questions before doing anything else:**

| Question | Why |
|---|---|
| **What percentage** of requests are failing? | 0.5% and 40% are different incidents |
| **Since when**, precisely? | To correlate with the deploy |
| **Which endpoints**? | One endpoint = a code path; all endpoints = a dependency |

---

## INVESTIGATE — but timebox it hard

**Give yourself 5 minutes.** If you don't have a confident cause by then, roll
back and investigate afterwards with no clock running.

```bash
# 1. Did this start when the deploy happened?
helm history orders-api -n orders
kubectl rollout history deployment/orders-api -n orders
```
```
REVISION  UPDATED                   STATUS      APP VERSION  DESCRIPTION
7         Wed Aug 26 09:15:00 2026  superseded  2.4.16       Upgrade complete
8         Wed Aug 26 13:51:00 2026  deployed    2.4.17       Upgrade complete
```

Errors started 13:52. The deploy was 13:51. That is not a coincidence, but it is
also not proof — check whether anything *else* changed at 13:51.

```bash
# 2. Is Kubernetes itself unhappy? (Often: no. That's the point.)
kubectl get pods -n orders                     # likely all 1/1 Running
kubectl get events -n orders --sort-by=.lastTimestamp | tail -20

# 3. Is it a MIXED FLEET rather than a bad version?
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17
```

> **Check the mixed-fleet case explicitly.** If half your pods are 2.4.16 and
> half are 2.4.17, "intermittent errors" may mean the rollout is stuck rather
> than that 2.4.17 is broken. The fix is different.

```bash
# 4. What do the errors actually say?
kubectl logs -n orders -l app.kubernetes.io/instance=orders-api --tail=500 \
  | grep -A5 '"severity":"ERROR"' | head -40
```

---

## CONFIRM the decision

Roll back when **any** of these is true:

- Users are affected **now**
- You don't have a confident root cause within your timebox
- The fix isn't a one-line change you're certain about
- Error rate or latency is trending **up**

Do **not** roll back when:

- The problem predates the deploy — you'd be reverting an innocent release and
  losing time
- The new version contains a fix for a *worse* problem
- Rolling back would break a completed database migration (see below)

> **Database migrations are the one genuine trap.** If 2.4.17 ran a migration
> that 2.4.16 cannot read, rolling back the application without rolling back the
> schema causes a *worse* outage. Check for migrations before rolling back.
> This is why backward-compatible migrations — expand/contract — matter.

**Announce it before you do it:**

> 🔴 **INCIDENT** — orders-api 2.4.17, deployed 13:51, is returning ~28% 500s on
> `/api/orders`. Rolling back to 2.4.16 now. Next update in 10 minutes.

---

## ROLLBACK

```bash
./scripts/rollback.sh -n orders
```

Or explicitly:

```bash
helm history orders-api -n orders          # ALWAYS look first
helm rollback orders-api 7 -n orders --wait --timeout 5m
```

> **"Roll back one revision" is not always right.** If the last three releases
> were all bad, one revision back is still broken. Read the history and pick a
> revision you know was good.

**If Helm is unavailable:**

```bash
kubectl rollout undo deployment/orders-api -n orders --to-revision=7
```

> ⚠️ This changes the live Deployment but **not** the Helm release. Helm now
> believes something different is deployed, and the next `helm upgrade` will
> silently re-apply the bad version. Reconcile as soon as the incident is over.

**If both are unavailable** — the break-glass option:

```bash
kubectl set image deployment/orders-api \
  orders-api=REGION-docker.pkg.dev/PROJECT/orders/orders-api:2.4.16 -n orders
```

**Emergency capacity** — if the issue is load rather than code:

```bash
kubectl scale deployment/orders-api --replicas=5 -n orders
```

---

## VERIFY

A rollback is not complete because the command returned 0.

```bash
kubectl rollout status deployment/orders-api -n orders --timeout=5m
kubectl get pods -n orders -L app.kubernetes.io/version
./scripts/verify-version.sh -n orders -r orders-api -v 2.4.16
```

**Then confirm the user-facing symptom is actually gone** — this is the step
people skip:

```bash
for i in $(seq 1 60); do
  curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/api/orders
done | sort | uniq -c
```
```
     60 200          ← the incident is over
```

Real output from this project's rollback drill:

```
before rollback:  200s: 43   non-200: 17   (out of 60)
after rollback:   200s: 60   non-200: 0    (out of 60)
```

---

## CHECK LOGS — before the evidence disappears

```bash
./scripts/collect-logs.sh -n orders
```

**Do this now, not later.** The old pods are being deleted as the rollback
completes, and with them their logs. Events expire after ~1 hour.

```bash
# The failing version's last words
kubectl logs -n orders POD_FROM_2417 --previous --tail=200
```

Note the **image digest** of the bad version. You'll want to reproduce it in a
non-production cluster later, and the tag alone may not be enough.

---

## COMMUNICATE

> ✅ **RESOLVED** — orders-api rolled back to 2.4.16 at 14:11.
> Error rate back to 0% (60/60 requests succeeding). 2/2 replicas healthy.
>
> **Impact:** ~19 minutes, ~28% of `/api/orders` requests returned 500.
> **Cause:** under investigation — 2.4.17 is frozen pending RCA.
> **Next:** postmortem by Friday.

Then **freeze the bad version** so nobody redeploys it by accident:

- Mark the release as bad in your tracker
- If your pipeline supports it, block the tag
- Tell the application team explicitly — they may be about to retry

---

## DOCUMENT — the postmortem

Blameless. The question is never "who deployed it" but "what let a broken
release reach users."

### Timeline
| Time (UTC) | Event |
|---|---|
| 13:51 | 2.4.17 deployed via pipeline; all checks green |
| 13:52 | First 500s in the logs |
| 14:03 | `HighErrorRate` alert fires (11 min detection gap) |
| 14:05 | On-call acknowledges, begins triage |
| 14:08 | Correlated with the deploy; rollback decision |
| 14:11 | Rollback complete, error rate at 0% |

### Impact
19 minutes. ~28% of `/api/orders` requests failed. ~1,400 requests affected.

### What went wrong
2.4.17 introduced a null-dereference on a code path exercised by ~30% of
requests. It passed unit tests because the failing input shape wasn't covered.

### Why the pipeline didn't catch it
The smoke test issued **one** request to `/api/orders`. With a 30% failure rate,
a single request passes 70% of the time.

### What went well
- `--atomic` was in place (this failure was in the app, not the rollout, so it
  didn't trigger — but it would have caught a crash-loop)
- Rollback took 3 minutes from decision to resolution
- Structured logs with request IDs made the failing code path obvious

### Action items
| # | Action | Owner | Due |
|---|---|---|---|
| 1 | Smoke test to issue 20+ requests and assert 100% success | DevOps | +1 week |
| 2 | Alert on 5xx rate > 1% for 2 min (was 5 min → 11 min detection gap) | DevOps | +3 days |
| 3 | Add the failing input shape to the unit-test suite | App team | +1 week |
| 4 | Evaluate canary deploys — 5% of traffic for 10 min before full rollout | DevOps | +1 month |

> Note that **three of four action items are not about the bug.** The bug is the
> app team's. The incident is about detection and blast radius, which is yours.

---

## Command reference

```bash
# See what you can roll back to
helm history orders-api -n orders
kubectl rollout history deployment/orders-api -n orders
kubectl rollout history deployment/orders-api -n orders --revision=7

# Roll back
helm rollback orders-api 7 -n orders --wait
kubectl rollout undo deployment/orders-api -n orders --to-revision=7

# Watch it happen
kubectl rollout status deployment/orders-api -n orders
kubectl get pods -n orders -w

# Emergency
kubectl set image deployment/orders-api orders-api=IMAGE:2.4.16 -n orders
kubectl scale deployment/orders-api --replicas=5 -n orders
kubectl rollout pause deployment/orders-api -n orders     # freeze mid-rollout
kubectl rollout resume deployment/orders-api -n orders
```

> **`revisionHistoryLimit: 10`** in the chart caps how far back you can go.
> `kubectl rollout undo --to-revision` cannot reach a ReplicaSet that has been
> garbage collected.

---

## Practise it

```bash
./failure-lab/run.sh start 15     # 30% 500s, all probes green
./scripts/health-check.sh -n orders
./scripts/rollback.sh -n orders
```

The first time you run a rollback should not be during an incident.

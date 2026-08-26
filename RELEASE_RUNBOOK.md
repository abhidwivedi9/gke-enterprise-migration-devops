# Release Runbook

The versioning and release process. For the mechanics of a single deploy, see
[REAL_DEVOPS_SUPPORT_WORKFLOW.md](REAL_DEVOPS_SUPPORT_WORKFLOW.md).

---

## Versioning

Semantic versioning: `MAJOR.MINOR.PATCH`.

| Bump | When | Example |
|---|---|---|
| MAJOR | Breaking API change | 2.4.17 → 3.0.0 |
| MINOR | Backward-compatible feature | 2.4.17 → 2.5.0 |
| PATCH | Backward-compatible fix | 2.4.16 → 2.4.17 |

**Two versions, deliberately kept separate:**

| Field | In | Bump when |
|---|---|---|
| `version` | `Chart.yaml` | The chart templates change |
| `appVersion` | `Chart.yaml` | The application image changes |

Conflating them is a common mistake. `helm list` shows both, and during an
incident "which chart shipped which app version" is only answerable if they've
been maintained honestly.

**Never `latest`.** A mutable tag cannot be rolled back to and cannot be verified
after the fact. The chart *fails to render* on `image.tag: latest`, and both
`build.sh` and `deploy.sh` refuse it.

---

## Cutting a release

```bash
# 1. Everything merged, CI green
git checkout main && git pull

# 2. Bump appVersion in Chart.yaml (and version, if templates changed)
#    appVersion: "2.4.17"

# 3. Commit and tag — the tag is what triggers the pipeline
git commit -am "release: 2.4.17"
git tag -a v2.4.17 -m "Fix duplicate order IDs on retry (ORD-4470)"
git push origin main --tags
```

The tag push triggers `.github/workflows/deploy-dev.yml`.

> **Tag from a clean tree.** `build.sh` refuses to build from a dirty working
> tree without `--allow-dirty`, because a build you cannot reproduce is a build
> you cannot audit.

---

## What the pipeline does

```
lint → test → bandit → pip-audit
  → docker build  (identity baked in via --build-arg)
       → ASSERT the baked-in version matches what was requested
       → ASSERT the image does not run as root
  → Trivy scan (fails on CRITICAL)
  → OIDC auth to GCP (no JSON key)
  → push to Artifact Registry
       → resolve the DIGEST; everything downstream uses it
  → helm upgrade --wait --atomic --set image.digest=…
  → kubectl rollout status
  → VERIFY VERSION  (9 layers, ending at the app's own /version)
  → smoke test: 20 requests against /api/orders
  → migration-validation.sh
```

**The four things to watch, in order:**

1. **Authenticate to Google Cloud** — a failure here is almost always the WIF
   `attribute_condition` not matching your repo, or the job missing
   `permissions: id-token: write`.
2. **Push image** — note the digest. It's the artifact identity.
3. **Verify deployed version** — *the* gate. Without it, SUCCESS means only that
   the pipeline ran, not that the right code is serving.
4. **Post-deployment validation** — business endpoints, 20 requests. One request
   against a 30% failure rate passes 70% of the time.

---

## Release checklist

**Before**
- [ ] All PRs merged, CI green on `main`
- [ ] `appVersion` bumped in `Chart.yaml`
- [ ] CHANGELOG updated
- [ ] Breaking changes communicated
- [ ] Database migrations backward compatible — **otherwise rollback is impossible**
- [ ] Rollback target identified: `helm history orders-api -n orders`

**During**
- [ ] Pipeline green through every stage
- [ ] Version verification passed
- [ ] Smoke test 20/20

**After**
- [ ] `/version` reports the new version, sampled repeatedly
- [ ] Error rate at baseline
- [ ] p95 latency within ~20% of baseline
- [ ] Zero restarts
- [ ] Dashboard watched for 10–15 minutes
- [ ] Ticket closed with version, commit, digest, and **the rollback command**

---

## Emergency / hotfix release

The process is the same. Do not skip verification because it's urgent — an
unverified hotfix is how a small incident becomes a large one.

```bash
git checkout -b hotfix/2.4.18 v2.4.17
# ... fix ...
git commit -am "fix: null deref on retry path"
git tag -a v2.4.18 -m "HOTFIX: null dereference"
git push origin hotfix/2.4.18 --tags
```

What you *may* compress under time pressure:
- the 10–15 minute dashboard watch (still watch 5)
- the full `migration-validation.sh` (still run `verify-version.sh`)

What you may **never** skip:
- version verification
- the smoke test against business endpoints
- knowing your rollback target before you deploy

---

## Release cadence

| Type | Cadence | Approval |
|---|---|---|
| Patch | as needed | DevOps |
| Minor | weekly | app owner |
| Major | planned | app owner + manager |
| Hotfix | immediate | on-call, retro-approved |

**Avoid Friday releases** unless someone is genuinely available all weekend. The
cost isn't the deploy — it's the 40 hours before anyone notices a slow leak.

---

## If a release goes wrong

1. **Roll back.** Stop the impact. → [ROLLBACK_RUNBOOK.md](ROLLBACK_RUNBOOK.md)
2. Freeze the bad version so nobody redeploys it.
3. Preserve evidence: `./scripts/collect-logs.sh -n orders`
4. Postmortem — blameless, with concrete action items.

**Rolling back is not a failure.** It's the option you built deliberately.

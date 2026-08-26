# Contributing

This is a portfolio and learning repository, but it's maintained to the standard
it teaches. If a change wouldn't pass review at work, it doesn't belong here.

## Setup

```bash
git clone https://github.com/OWNER/gke-enterprise-migration-devops
cd gke-enterprise-migration-devops

pip install -r app/requirements-dev.txt
./scripts/local-up.sh          # 3-node kind cluster, $0
```

Required: Docker, kind, kubectl, helm. Optional: terraform, gcloud.

## Before opening a PR

```bash
ruff check .
pytest -q
bandit -r app/src -ll

helm lint helm/application -f helm/application/values.yaml
helm template orders-api helm/application \
  -f helm/application/values.yaml -f helm/application/values-local.yaml -n orders

terraform fmt -check -recursive terraform/
cd terraform/environments/dev && terraform init -backend=false && terraform validate

docker run --rm -v "$(pwd):/mnt" koalaman/shellcheck:stable \
  --severity=warning /mnt/scripts/build.sh   # …and the rest
```

CI runs all of these. Running them locally is faster than waiting for a red
build.

## Standards

**Comments explain WHY, not WHAT.** The code already says what it does.

```yaml
# Bad
maxUnavailable: 0   # set maxUnavailable to 0

# Good
# maxUnavailable: 0 — never drop below the desired replica count during a
# rollout, so a deploy under load does not shed traffic.
maxUnavailable: 0
```

**Every non-obvious setting carries its reason.** Someone reading this repo
should learn *why* a value is what it is. That's the entire point of the project.

**Scripts:**
- `set -uo pipefail` (add `-e` only where you aren't handling exits yourself)
- shellcheck clean at `--severity=warning`
- a usage block and `-h/--help`
- exit non-zero on failure, and say what to do next

**Never parse `kubectl --no-headers` positionally with awk.** Fields can contain
spaces — `kubectl get hpa` prints TARGETS as `cpu: 12%/70%`, two tokens, which
silently shifts every column after it. Use `-o jsonpath` or `-o custom-columns`.
This exact bug shipped in this repo's own dashboard and was caught by running it.

**Cost:** anything that creates a billable GCP resource must be behind a flag
defaulting to `false`, with the cost documented in the variable description
**and** in [COST_CONTROL.md](COST_CONTROL.md).

**Security:** no credentials, ever. No service-account keys, no real project IDs,
no internal hostnames. See [SECURITY.md](SECURITY.md).

## Adding a failure-lab scenario

1. Add the case to `failure-lab/run.sh` (`scenario_title` and `start_scenario`)
2. Add the write-up to `failure-lab/README.md` as `## NN Title`, following
   SYMPTOM → COMMAND → OUTPUT → ROOT CAUSE → FIX → VALIDATION → PREVENTION →
   INTERVIEW QUESTION
3. **Actually run it** and paste the real output, not what you expect it to be
4. Make sure `reset` cleans it up

The `explain` subcommand parses the README, so the heading format matters.

> When scenario 01 was first written, the documented exit code was 1 — the value
> the application passes to `sys.exit()`. Running it showed exit **3**, because
> uvicorn catches `SystemExit` and exits with its own code. That correction is
> now one of the more useful paragraphs in the lab. Run your scenario.

## Documentation

Claims must be verifiable. If you write "this reduces cost by 60%", say against
what, and where the number comes from.

**Never claim something was tested that wasn't.**
[VALIDATION_REPORT.md](VALIDATION_REPORT.md) draws a hard line between verified
and unverified — keep it honest. A repository that overstates what it has proven
is worse than one that admits its gaps.

## Commits

```
feat: add PodMonitoring template for Managed Prometheus
fix: HPA panel mis-parsed kubectl output when TARGETS contained a space
docs: explain why liveness must not check dependencies
```

Conventional Commits. Explain *why* in the body when it isn't obvious.

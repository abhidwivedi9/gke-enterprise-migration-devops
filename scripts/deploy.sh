#!/usr/bin/env bash
#
# deploy.sh — deploy a version, and refuse to report success unless it is real.
#
# The behaviour that matters here is what happens on FAILURE. A deploy script
# that exits 0 because `helm upgrade` returned 0 is worse than no script at all:
# it manufactures false confidence. This one waits for the rollout, verifies the
# running version, and tells you exactly how to roll back if any of that fails.
#
# Usage:
#   ./scripts/deploy.sh 2.4.17 --env local
#   ./scripts/deploy.sh 2.4.17 --env dev --registry us-central1-docker.pkg.dev/proj/orders
#   ./scripts/deploy.sh 2.4.17 --env dev --dry-run

set -uo pipefail

VERSION="${1:-}"
shift || true

ENVIRONMENT="local"
NAMESPACE="orders"
RELEASE="orders-api"
REGISTRY=""
DRY_RUN=false
TIMEOUT="5m"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

if [[ -z "$VERSION" ]]; then
  cat <<'USAGE'
Usage: deploy.sh VERSION [options]
  --env ENV         local | dev   (default: local)
  --namespace NS    default: orders
  --release NAME    default: orders-api
  --registry PATH   Artifact Registry path (required for --env dev)
  --dry-run         Render and diff only; change nothing
  --timeout DUR     Rollout wait (default: 5m)
USAGE
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.." || { echo "cannot cd to repo root" >&2; exit 1; }

if [[ "$VERSION" == "latest" ]]; then
  echo "${RED}Refusing to deploy ':latest'. It cannot be rolled back to or verified.${NC}" >&2
  exit 2
fi

VALUES_FILE="helm/application/values-${ENVIRONMENT}.yaml"
if [[ ! -f "$VALUES_FILE" ]]; then
  echo "${RED}No values file at $VALUES_FILE${NC}" >&2
  exit 2
fi

HELM_ARGS=(
  upgrade --install "$RELEASE" ./helm/application
  -f helm/application/values.yaml
  -f "$VALUES_FILE"
  -n "$NAMESPACE" --create-namespace
  --set "image.tag=${VERSION}"
)
[[ -n "$REGISTRY" ]] && HELM_ARGS+=(--set "image.repository=${REGISTRY}/orders-api")

echo "========================================================================"
echo " DEPLOY"
echo "   version   : $VERSION"
echo "   env       : $ENVIRONMENT"
echo "   release   : $RELEASE   namespace: $NAMESPACE"
echo "   context   : $(kubectl config current-context 2>/dev/null || echo '<none>')"
echo "========================================================================"

# ---------------------------------------------------------------------------
# PRE-FLIGHT. Confirm which cluster you are about to change.
#
# Deploying to the wrong cluster because kubectl context was left pointing
# somewhere else is a genuinely common production incident. Print it, loudly.
# ---------------------------------------------------------------------------
CURRENT_CTX="$(kubectl config current-context 2>/dev/null || echo '')"
if [[ -z "$CURRENT_CTX" ]]; then
  echo "${RED}No kubectl context. Run: gcloud container clusters get-credentials ...${NC}" >&2
  exit 1
fi
if [[ "$ENVIRONMENT" != "local" && "$CURRENT_CTX" == kind-* ]]; then
  echo "${RED}Refusing: --env $ENVIRONMENT but the context is a local kind cluster ($CURRENT_CTX).${NC}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# CAPTURE THE ROLLBACK TARGET **BEFORE** CHANGING ANYTHING.
#
# After a bad deploy you want this number immediately, not after five minutes
# of scrolling `helm history` under pressure.
# ---------------------------------------------------------------------------
PREVIOUS_REVISION="$(helm list -n "$NAMESPACE" -f "^${RELEASE}\$" -o json 2>/dev/null \
  | grep -o '"revision":"\?[0-9]*"\?' | head -1 | tr -dc '0-9' || echo "")"
if [[ -n "$PREVIOUS_REVISION" ]]; then
  echo "${YELLOW}Current revision is $PREVIOUS_REVISION. If this deploy goes wrong:${NC}"
  echo "${YELLOW}    helm rollback $RELEASE $PREVIOUS_REVISION -n $NAMESPACE --wait${NC}"
  echo
else
  echo "${BLUE}First install of this release — there is no rollback target yet.${NC}"
  echo
fi

# ---------------------------------------------------------------------------
# DRY RUN: show what would change, change nothing.
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
  echo "--- DRY RUN: rendering manifests ---"
  helm "${HELM_ARGS[@]}" --dry-run --debug 2>&1 | sed -n '/^---/,$p' | head -120
  echo
  echo "${GREEN}Dry run only. Nothing was changed.${NC}"
  exit 0
fi

# ---------------------------------------------------------------------------
# APPLY.
#
# --wait --atomic is the important pair:
#   --wait   : block until pods are Ready, not merely until the API accepted YAML
#   --atomic : if the wait fails, AUTOMATICALLY roll back to the previous
#              revision instead of leaving a half-broken release in place
# ---------------------------------------------------------------------------
echo "--- helm upgrade --install ---"
helm "${HELM_ARGS[@]}" --wait --atomic --timeout "$TIMEOUT"
HELM_EXIT=$?

if [[ $HELM_EXIT -ne 0 ]]; then
  echo
  echo "${RED}DEPLOY FAILED (helm exit $HELM_EXIT).${NC}"
  echo "--atomic will have rolled back automatically. Confirm the current state:"
  echo "    helm history $RELEASE -n $NAMESPACE"
  echo "    kubectl get pods -n $NAMESPACE"
  echo "    kubectl describe pod -n $NAMESPACE -l app.kubernetes.io/instance=$RELEASE | tail -40"
  echo "    kubectl get events -n $NAMESPACE --sort-by=.lastTimestamp | tail -20"
  echo
  echo "Diagnose with TROUBLESHOOTING.md."
  exit 1
fi

# ---------------------------------------------------------------------------
# POST-DEPLOY VERIFICATION. This is the part most scripts skip.
# ---------------------------------------------------------------------------
echo
echo "--- rollout status ---"
kubectl rollout status "deployment/${RELEASE}" -n "$NAMESPACE" --timeout="$TIMEOUT" || {
  echo "${RED}Rollout did not complete.${NC}"
  exit 1
}

echo
echo "--- verifying the running version ---"
if bash "$(dirname "$0")/verify-version.sh" -n "$NAMESPACE" -r "$RELEASE" -v "$VERSION" ${REGISTRY:+--registry "$REGISTRY"}; then
  echo
  echo "${GREEN}========================================================================${NC}"
  echo "${GREEN} DEPLOY COMPLETE AND VERIFIED: $VERSION is live in $NAMESPACE.${NC}"
  echo "${GREEN}========================================================================${NC}"
  exit 0
else
  echo
  echo "${RED}========================================================================${NC}"
  echo "${RED} DEPLOYED, BUT VERIFICATION FAILED.${NC}"
  echo "${RED} Do NOT tell the application team this is done.${NC}"
  echo "${RED}========================================================================${NC}"
  [[ -n "$PREVIOUS_REVISION" ]] && \
    echo " Roll back with: helm rollback $RELEASE $PREVIOUS_REVISION -n $NAMESPACE --wait"
  exit 1
fi

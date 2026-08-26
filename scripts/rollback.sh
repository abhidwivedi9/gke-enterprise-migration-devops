#!/usr/bin/env bash
#
# rollback.sh — get production back to a known-good version, fast.
#
# ROLLBACK IS NOT A FAILURE. It is the correct first response to a bad release.
# Rolling back in 3 minutes and investigating afterwards beats debugging in
# production for 40 minutes while users are affected. Stop the bleeding first.
#
# Usage:
#   ./scripts/rollback.sh                       # roll back one revision
#   ./scripts/rollback.sh --to-revision 7
#   ./scripts/rollback.sh --list                # just show history and exit
#   ./scripts/rollback.sh --kubectl             # use kubectl rollout undo instead

set -uo pipefail

NAMESPACE="orders"
RELEASE="orders-api"
TO_REVISION=""
LIST_ONLY=false
USE_KUBECTL=false
TIMEOUT="5m"
YES=false

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release) RELEASE="$2"; shift 2 ;;
    --to-revision) TO_REVISION="$2"; shift 2 ;;
    --list) LIST_ONLY=true; shift ;;
    --kubectl) USE_KUBECTL=true; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -y|--yes) YES=true; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: rollback.sh [options]
  -n, --namespace NS     default: orders
  -r, --release NAME     default: orders-api
      --to-revision N    target revision (default: previous)
      --list             show history, change nothing
      --kubectl          use `kubectl rollout undo` instead of Helm
  -y, --yes              skip the confirmation prompt (for automation)
USAGE
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

echo "========================================================================"
echo " ROLLBACK — $RELEASE in $NAMESPACE"
echo " context: $(kubectl config current-context 2>/dev/null || echo '<none>')"
echo "========================================================================"

# ---------------------------------------------------------------------------
# ALWAYS show the history first. You cannot choose a rollback target you have
# not looked at, and "roll back one" is not always the right answer — if the
# last three releases were all bad, one revision back is still broken.
# ---------------------------------------------------------------------------
echo
echo "--- helm history ---"
helm history "$RELEASE" -n "$NAMESPACE" 2>/dev/null || {
  echo "${YELLOW}No Helm history. Falling back to kubectl rollout history.${NC}"
  USE_KUBECTL=true
}

if [[ "$USE_KUBECTL" == true ]]; then
  echo
  echo "--- kubectl rollout history ---"
  # CHANGE-CAUSE is populated by the chart's kubernetes.io/change-cause
  # annotation. Without it this table is meaningless numbers.
  kubectl rollout history "deployment/${RELEASE}" -n "$NAMESPACE" 2>/dev/null || true
fi

if [[ "$LIST_ONLY" == true ]]; then
  echo
  echo "History only — nothing changed."
  exit 0
fi

# ---------------------------------------------------------------------------
# Record the CURRENT state before changing it, so the rollback itself is
# reversible and the incident timeline is accurate.
# ---------------------------------------------------------------------------
CURRENT_IMAGE="$(kubectl get deployment "$RELEASE" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo unknown)"
CURRENT_REVISION="$(helm list -n "$NAMESPACE" -f "^${RELEASE}\$" -o json 2>/dev/null \
  | grep -o '"revision":"\?[0-9]*"\?' | head -1 | tr -dc '0-9' || echo "")"

echo
echo "Currently deployed:"
echo "   image    : $CURRENT_IMAGE"
echo "   revision : ${CURRENT_REVISION:-unknown}"
echo "   time     : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ -z "$TO_REVISION" && -n "$CURRENT_REVISION" && "$CURRENT_REVISION" -gt 1 ]]; then
  TO_REVISION=$((CURRENT_REVISION - 1))
fi

if [[ -z "$TO_REVISION" ]]; then
  echo "${RED}No rollback target available — this appears to be revision 1.${NC}" >&2
  echo "There is no previous version to return to. Fix forward instead." >&2
  exit 1
fi

echo
echo "${YELLOW}Rolling back to revision $TO_REVISION.${NC}"

if [[ "$YES" != true ]]; then
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------------------
# Execute.
# ---------------------------------------------------------------------------
echo
if [[ "$USE_KUBECTL" == true ]]; then
  echo "--- kubectl rollout undo ---"
  # NOTE: kubectl rollout undo changes the live Deployment but does NOT update
  # the Helm release. Helm now believes something different is deployed, and
  # the next `helm upgrade` will silently re-apply the bad version. Use this
  # only when Helm is unavailable, and reconcile immediately afterwards.
  echo "${YELLOW}WARNING: this bypasses Helm. Helm state will be stale until you re-sync.${NC}"
  kubectl rollout undo "deployment/${RELEASE}" -n "$NAMESPACE" --to-revision="$TO_REVISION"
else
  echo "--- helm rollback ---"
  helm rollback "$RELEASE" "$TO_REVISION" -n "$NAMESPACE" --wait --timeout "$TIMEOUT"
fi

ROLLBACK_EXIT=$?
if [[ $ROLLBACK_EXIT -ne 0 ]]; then
  echo "${RED}ROLLBACK COMMAND FAILED (exit $ROLLBACK_EXIT). Escalate now.${NC}" >&2
  echo "Manual override, if the rollback target image is known:" >&2
  echo "  kubectl set image deployment/$RELEASE $RELEASE=<KNOWN_GOOD_IMAGE> -n $NAMESPACE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Verify. A rollback is not complete because the command returned 0.
# ---------------------------------------------------------------------------
echo
echo "--- rollout status ---"
kubectl rollout status "deployment/${RELEASE}" -n "$NAMESPACE" --timeout="$TIMEOUT"

echo
echo "--- state after rollback ---"
NEW_IMAGE="$(kubectl get deployment "$RELEASE" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "   image before : $CURRENT_IMAGE"
echo "   image now    : $NEW_IMAGE"

kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE}" \
  -L app.kubernetes.io/version

echo
echo "--- confirming the application agrees ---"
PF_PORT=18098
kubectl port-forward -n "$NAMESPACE" "svc/${RELEASE}" "${PF_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
trap '[[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 3
RUNNING_VERSION="$(curl -s --max-time 5 "http://127.0.0.1:${PF_PORT}/version" 2>/dev/null \
  | grep -o '"application_version":"[^"]*"' | cut -d'"' -f4 || true)"

if [[ -n "$RUNNING_VERSION" ]]; then
  echo "${GREEN}   /version now reports: $RUNNING_VERSION${NC}"
else
  echo "${YELLOW}   could not read /version — check pods are Ready and endpoints exist${NC}"
fi

cat <<EOF

========================================================================
${GREEN} ROLLBACK COMPLETE${NC}

 STILL TO DO — the rollback is the start of the incident, not the end:

   1. CONFIRM the user-facing symptom is gone (error rate, latency, the
      original complaint). A green deploy is not a resolved incident.
   2. COMMUNICATE: tell the channel what you rolled back, to which version,
      and at what time.
   3. FREEZE the bad version so nobody redeploys it by accident.
   4. PRESERVE EVIDENCE before the old pods are garbage collected:
        ./scripts/collect-logs.sh -n $NAMESPACE
   5. WRITE THE POSTMORTEM. Blameless, with a timeline and concrete
      prevention items. See ROLLBACK_RUNBOOK.md.
========================================================================
EOF

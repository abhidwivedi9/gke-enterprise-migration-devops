#!/usr/bin/env bash
#
# run-all.sh — regression-test the failure lab itself.
#
# For every scenario: inject it, ASSERT the expected symptom actually appears,
# reset, and assert the cluster is healthy again. Prints a summary table.
#
# WHY THIS EXISTS. A failure lab whose scenarios do not reproduce is worse than
# no lab: you spend twenty minutes diagnosing a symptom that was never injected.
# Documentation drifts from behaviour silently, and the only way to know is to
# run it. (Scenario 01's documented exit code was wrong until it was run.)
#
# This is NOT how to learn the scenarios - it gives away every answer. Use
# `run.sh start NN` for that. This is the check that the lab still works, for
# after a chart change or a Kubernetes upgrade.
#
#   ./failure-lab/run-all.sh              # all 15
#   ./failure-lab/run-all.sh 02 04 07     # only these
#   ./failure-lab/run-all.sh --quick      # skip the slow ones (04, 07)
#
# Runtime: roughly 15-25 minutes for all 15. Cost: $0 on kind.

set -uo pipefail

NAMESPACE="${LAB_NAMESPACE:-orders}"
RELEASE="${LAB_RELEASE:-orders-api}"
QUICK=false

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'

cd "$(dirname "$0")/.." || { echo "cannot cd to repo root" >&2; exit 1; }

SCENARIOS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    [0-9][0-9]) SCENARIOS+=("$1"); shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
  SCENARIOS=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15)
  $QUICK && SCENARIOS=(01 02 03 05 06 08 09 10 11 12 13 14 15)
fi

PASSED=(); FAILED=(); SKIPPED=()

# ---------------------------------------------------------------------------
# Poll for a condition rather than sleeping a fixed amount. Scenarios manifest
# at very different speeds - an ImagePullBackOff appears in seconds, an
# OOMKill needs the container to allocate first.
# ---------------------------------------------------------------------------
wait_for() {
  local desc="$1" timeout="$2" check="$3" elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if eval "$check" >/dev/null 2>&1; then
      printf '    %s✓%s %s (after %ss)\n' "$GREEN" "$NC" "$desc" "$elapsed"
      return 0
    fi
    sleep 5; elapsed=$((elapsed+5))
  done
  printf '    %s✗%s %s - NOT observed within %ss\n' "$RED" "$NC" "$desc" "$timeout"
  return 1
}

# Any container waiting with the given reason.
has_waiting_reason() {
  kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[*].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
    | grep -q "$1"
}

has_pending_pod() {
  kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
    --field-selector=status.phase=Pending -o name 2>/dev/null | grep -q pod/
}

has_terminated_reason() {
  kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[*].lastState.terminated.reason}{"\n"}{end}' 2>/dev/null \
    | grep -q "$1"
}

has_restarts() {
  local n
  n=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null \
    | awk '{s+=$1} END {print s+0}')
  [[ "${n:-0}" -gt 0 ]]
}

# A pod that is Running but whose Ready condition is false.
has_running_not_ready() {
  kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
    -o jsonpath='{range .items[*]}{.status.phase}{"="}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -qi '^Running=False'
}

endpoints_count() {
  kubectl get endpoints "$RELEASE" -n "$NAMESPACE" \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w
}

env_value() {
  kubectl get deployment "$RELEASE" -n "$NAMESPACE" \
    -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='$1')].value}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Per-scenario assertion: did the intended symptom actually appear?
# ---------------------------------------------------------------------------
assert_scenario() {
  case "$1" in
    01) wait_for "CrashLoopBackOff or restarts" 150 'has_waiting_reason CrashLoopBackOff || has_restarts' ;;
    02) wait_for "ImagePullBackOff/ErrImagePull" 120 'has_waiting_reason ImagePullBackOff || has_waiting_reason ErrImagePull' ;;
    03) wait_for "a Pending pod" 120 'has_pending_pod' ;;
    04) wait_for "OOMKilled (exit 137)" 240 'has_terminated_reason OOMKilled || has_restarts' ;;
    05) wait_for "Running but NOT Ready" 150 'has_running_not_ready' ;;
    06) wait_for "restarts from liveness failure" 180 'has_restarts' ;;
    07) wait_for "startup probe kills a slow boot" 210 'has_restarts || has_running_not_ready || has_waiting_reason CrashLoopBackOff' ;;
    08) wait_for "fail-fast on the missing Secret" 180 'has_restarts || has_waiting_reason CrashLoopBackOff || has_waiting_reason CreateContainerConfigError || has_running_not_ready' ;;
    09) wait_for "LOG_LEVEL=CRITICAL applied" 150 '[[ "$(env_value LOG_LEVEL)" == "CRITICAL" ]] || kubectl get cm '"$RELEASE"'-config -n '"$NAMESPACE"' -o jsonpath="{.data.LOG_LEVEL}" | grep -q CRITICAL' ;;
    # 10: the whole point is that nothing LOOKS wrong - so assert that
    # verify-version FAILS for the version everything claims to be running.
    10) wait_for "verify-version rejects the claimed 2.4.18" 90 '! bash scripts/verify-version.sh -n '"$NAMESPACE"' -r '"$RELEASE"' -v 2.4.18 >/dev/null 2>&1' ;;
    11) wait_for "PDB ALLOWED DISRUPTIONS = 0" 150 '[[ "$(kubectl get pdb '"$RELEASE"' -n '"$NAMESPACE"' -o jsonpath="{.status.disruptionsAllowed}" 2>/dev/null)" == "0" ]]' ;;
    12) wait_for "KSA annotated with the wrong GSA" 90 'kubectl get sa '"$RELEASE"' -n '"$NAMESPACE"' -o jsonpath="{.metadata.annotations.iam\.gke\.io/gcp-service-account}" 2>/dev/null | grep -q wrong-sa' ;;
    13) wait_for "CPU request removed (HPA blinded)" 120 '[[ -z "$(kubectl get deployment '"$RELEASE"' -n '"$NAMESPACE"' -o jsonpath="{.spec.template.spec.containers[0].resources.requests.cpu}" 2>/dev/null)" ]]' ;;
    14) wait_for "Service endpoints drop to zero" 90 '[[ "$(endpoints_count)" -eq 0 ]]' ;;
    15) wait_for "ERROR_RATE_PERCENT injected" 150 '[[ -n "$(env_value ERROR_RATE_PERCENT)" ]]' ;;
    *)  return 1 ;;
  esac
}

# A scenario is only genuinely usable if reset returns the cluster to healthy.
assert_reset_healthy() {
  wait_for "cluster healthy again after reset" 240 \
    '[[ "$(kubectl get deployment '"$RELEASE"' -n '"$NAMESPACE"' -o jsonpath="{.status.availableReplicas}" 2>/dev/null)" -ge 1 ]] && [[ "$(endpoints_count)" -ge 1 ]]'
}

echo "${BOLD}========================================================================${NC}"
echo "${BOLD} FAILURE LAB REGRESSION — ${#SCENARIOS[@]} scenario(s)${NC}"
echo "${BOLD}========================================================================${NC}"
echo "  namespace : $NAMESPACE"
echo "  context   : $(kubectl config current-context 2>/dev/null)"
echo "  NOTE      : this reveals every answer. To LEARN, use run.sh start NN."
echo

if ! kubectl get deployment "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "${RED}No deployment '$RELEASE' in '$NAMESPACE'. Run ./scripts/local-up.sh first.${NC}" >&2
  exit 1
fi

START=$(date +%s)
for id in "${SCENARIOS[@]}"; do
  # Title comes from `run.sh list` ("  NN  Title"), not from `explain`, whose
  # second line is a box-drawing rule.
  title="$(bash failure-lab/run.sh list 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | awk -v id="$id" '$1==id {$1=""; sub(/^ +/,""); print; exit}')"
  echo "${BLUE}${BOLD}--- $id : ${title:-unknown}${NC}"

  if ! bash failure-lab/run.sh start "$id" >/dev/null 2>&1; then
    echo "    ${RED}✗ injection command failed${NC}"
    FAILED+=("$id (inject)"); bash failure-lab/run.sh reset >/dev/null 2>&1; continue
  fi

  if assert_scenario "$id"; then
    SYMPTOM_OK=true
  else
    SYMPTOM_OK=false
  fi

  bash failure-lab/run.sh reset >/dev/null 2>&1
  if assert_reset_healthy; then RESET_OK=true; else RESET_OK=false; fi

  if $SYMPTOM_OK && $RESET_OK; then
    PASSED+=("$id"); echo "    ${GREEN}PASS${NC}"
  elif ! $SYMPTOM_OK; then
    FAILED+=("$id (symptom)"); echo "    ${RED}FAIL - symptom did not reproduce${NC}"
  else
    FAILED+=("$id (reset)"); echo "    ${RED}FAIL - reset left the cluster unhealthy${NC}"
  fi
  echo
done

ELAPSED=$(( $(date +%s) - START ))
echo "${BOLD}========================================================================${NC}"
printf " passed: %s%d%s   failed: %s%d%s   skipped: %d   (%dm %ds)\n" \
  "$GREEN" "${#PASSED[@]}" "$NC" "$RED" "${#FAILED[@]}" "$NC" "${#SKIPPED[@]}" $((ELAPSED/60)) $((ELAPSED%60))
[[ ${#PASSED[@]} -gt 0 ]] && echo "   passed : ${PASSED[*]}"
[[ ${#FAILED[@]} -gt 0 ]] && echo "   ${RED}failed : ${FAILED[*]}${NC}"
echo "${BOLD}========================================================================${NC}"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "A failing scenario means the lab no longer matches its documentation."
  echo "Fix the scenario, or correct failure-lab/README.md - do not leave them disagreeing."
  exit 1
fi
echo "${GREEN}Every scenario reproduced its documented symptom and reset cleanly.${NC}"

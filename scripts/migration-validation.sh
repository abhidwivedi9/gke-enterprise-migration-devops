#!/usr/bin/env bash
#
# migration-validation.sh — the post-cutover sign-off sweep.
#
# Run this immediately after cutting traffic over to GKE, and again 1h, 4h and
# 24h later. It answers the question a migration lead actually asks: "can we
# tell the business the migration succeeded?"
#
# It is deliberately stricter than health-check.sh. Health is "is it up right
# now"; this is "is it correct, secure, observable, and reversible".
#
# Usage:
#   ./scripts/migration-validation.sh -n orders -v 2.4.17
#   ./scripts/migration-validation.sh -n orders -v 2.4.17 --gcp --project my-proj --cluster orders-api-dev-gke --zone us-central1-a

set -uo pipefail

NAMESPACE="orders"
RELEASE="orders-api"
EXPECTED_VERSION=""
CHECK_GCP=false
PROJECT_ID=""
CLUSTER=""
ZONE=""
PF_PORT=18095

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
PASS_N=0; FAIL_N=0; WARN_N=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release) RELEASE="$2"; shift 2 ;;
    -v|--version) EXPECTED_VERSION="$2"; shift 2 ;;
    --gcp) CHECK_GCP=true; shift ;;
    --project) PROJECT_ID="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    -h|--help) echo "Usage: migration-validation.sh -n NS -v VERSION [--gcp --project P --cluster C --zone Z]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$EXPECTED_VERSION" ]] && { echo "${RED}-v/--version is required${NC}" >&2; exit 2; }

section() { printf '\n%s########## %s ##########%s\n' "$BLUE" "$1" "$NC"; }
pass() { PASS_N=$((PASS_N+1)); printf '  %s[PASS]%s %s\n' "$GREEN" "$NC" "$1"; }
fail() { FAIL_N=$((FAIL_N+1)); printf '  %s[FAIL]%s %s\n' "$RED" "$NC" "$1"; }
warn() { WARN_N=$((WARN_N+1)); printf '  %s[WARN]%s %s\n' "$YELLOW" "$NC" "$1"; }
note() { printf '         %s\n' "$1"; }

echo "========================================================================"
echo " POST-MIGRATION VALIDATION"
echo "   version : $EXPECTED_VERSION"
echo "   target  : $RELEASE / $NAMESPACE"
echo "   context : $(kubectl config current-context 2>/dev/null)"
echo "   time    : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "========================================================================"

# ===========================================================================
section "1. INFRASTRUCTURE"
# ===========================================================================
NODES_TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
NODES_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
[[ "$NODES_READY" -eq "$NODES_TOTAL" && "$NODES_TOTAL" -gt 0 ]] \
  && pass "$NODES_READY/$NODES_TOTAL nodes Ready" \
  || fail "only $NODES_READY/$NODES_TOTAL nodes Ready"

# Node pressure conditions predict outages before they happen.
PRESSURE=$(kubectl get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.status=="True")]}{.type} {end}{end}' 2>/dev/null \
  | tr ' ' '\n' | grep -E 'MemoryPressure|DiskPressure|PIDPressure' | wc -l)
[[ "${PRESSURE:-0}" -eq 0 ]] \
  && pass "no node is reporting memory/disk/PID pressure" \
  || fail "$PRESSURE node pressure condition(s) active"

if $CHECK_GCP && [[ -n "$CLUSTER" && -n "$ZONE" && -n "$PROJECT_ID" ]]; then
  CSTATUS=$(gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT_ID" \
    --format='value(status)' 2>/dev/null || echo UNKNOWN)
  [[ "$CSTATUS" == "RUNNING" ]] && pass "GKE cluster status: RUNNING" || fail "GKE cluster status: $CSTATUS"
else
  note "GKE-specific checks skipped (pass --gcp with --project/--cluster/--zone)"
fi

# ===========================================================================
section "2. APPLICATION DEPLOYMENT"
# ===========================================================================
DESIRED=$(kubectl get deploy "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
AVAILABLE=$(kubectl get deploy "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
# jsonpath returns nothing at all when the field is absent, so normalise once
# here rather than sprinkling ${AVAILABLE:-0} through every message below.
AVAILABLE="${AVAILABLE:-0}"
if [[ -z "$DESIRED" ]]; then
  fail "Deployment $RELEASE does not exist in $NAMESPACE"
elif [[ "${AVAILABLE:-0}" -eq "$DESIRED" ]]; then
  pass "$AVAILABLE/$DESIRED replicas available"
else
  fail "${AVAILABLE:-0}/$DESIRED replicas available"
fi

RESTARTS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s+0}')
[[ "${RESTARTS:-0}" -eq 0 ]] && pass "zero restarts since cutover" || warn "$RESTARTS restart(s) — investigate before sign-off"

# Replicas spread across nodes: a migration that lands every pod on one node has
# not actually improved availability over the legacy single server.
UNIQUE_NODES=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | grep -c . || true)
[[ "${UNIQUE_NODES:-0}" -gt 1 ]] \
  && pass "pods spread across $UNIQUE_NODES nodes" \
  || warn "all pods are on ONE node — a single node failure is a full outage"

# ===========================================================================
section "3. VERSION CORRECTNESS"
# ===========================================================================
if bash "$(dirname "$0")/verify-version.sh" -n "$NAMESPACE" -r "$RELEASE" -v "$EXPECTED_VERSION" >/dev/null 2>&1; then
  pass "version verification passed end to end ($EXPECTED_VERSION)"
else
  fail "version verification FAILED — run ./scripts/verify-version.sh for detail"
fi

# ===========================================================================
section "4. TRAFFIC AND CORRECTNESS"
# ===========================================================================
kubectl port-forward -n "$NAMESPACE" "svc/$RELEASE" "${PF_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
trap '[[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 3

EP_COUNT=$(kubectl get endpoints "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
[[ "$EP_COUNT" -gt 0 ]] && pass "$EP_COUNT endpoint(s) behind the Service" || fail "Service has ZERO endpoints"

SUCCESS=0; TOTAL=50; LAT_TOTAL=0
for _ in $(seq 1 $TOTAL); do
  out=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 5 "http://127.0.0.1:${PF_PORT}/api/orders" 2>/dev/null || echo "000 0")
  code="${out%% *}"; t="${out##* }"
  [[ "$code" == "200" ]] && SUCCESS=$((SUCCESS+1))
  LAT_TOTAL=$(awk -v a="$LAT_TOTAL" -v b="$t" 'BEGIN{print a+b}')
done
RATE=$(( SUCCESS * 100 / TOTAL ))
AVG_MS=$(awk -v t="$LAT_TOTAL" -v n="$TOTAL" 'BEGIN{printf "%.0f", (t/n)*1000}')

[[ "$RATE" -eq 100 ]] && pass "$SUCCESS/$TOTAL requests succeeded (100%)" || fail "$SUCCESS/$TOTAL succeeded (${RATE}%) — users are seeing errors"
[[ "${AVG_MS:-9999}" -lt 500 ]] && pass "average latency ${AVG_MS}ms" || warn "average latency ${AVG_MS}ms — compare against the pre-migration baseline"
note "Latency here is measured THROUGH port-forward, which adds overhead."
note "For a real number, measure from where users actually are."

# ===========================================================================
section "5. SECURITY POSTURE"
# ===========================================================================
RUNS_AS_ROOT=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
  -o jsonpath='{range .items[*]}{.spec.securityContext.runAsUser}{"\n"}{end}' 2>/dev/null | grep -c '^0$' || true)
[[ "${RUNS_AS_ROOT:-0}" -eq 0 ]] && pass "no pod runs as root" || fail "$RUNS_AS_ROOT pod(s) run as UID 0"

PRIV=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.spec.containers[*].securityContext.privileged}{"\n"}{end}' 2>/dev/null | grep -c true || true)
[[ "${PRIV:-0}" -eq 0 ]] && pass "no privileged container" || fail "$PRIV privileged container(s)"

NO_LIMITS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
  -o jsonpath='{range .items[*]}{.spec.containers[0].resources.limits.memory}{"\n"}{end}' 2>/dev/null | grep -c '^$' || true)
[[ "${NO_LIMITS:-0}" -eq 0 ]] && pass "every container has a memory limit" || fail "$NO_LIMITS container(s) have no memory limit — one leak can take the node down"

SA_NAME=$(kubectl get deploy "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)
[[ -n "$SA_NAME" && "$SA_NAME" != "default" ]] \
  && pass "runs as a dedicated ServiceAccount ($SA_NAME)" \
  || fail "using the 'default' ServiceAccount"

if $CHECK_GCP; then
  WI_ANNOT=$(kubectl get sa "$SA_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}' 2>/dev/null || true)
  [[ -n "$WI_ANNOT" ]] && pass "Workload Identity annotation present ($WI_ANNOT)" \
                       || warn "no Workload Identity annotation — is the pod using a JSON key instead?"
fi

# ===========================================================================
section "6. RESILIENCE AND REVERSIBILITY"
# ===========================================================================
kubectl get hpa "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 && pass "HPA exists" || warn "no HPA — this workload cannot absorb a traffic spike"
HPA_TARGETS=$(kubectl get hpa "$RELEASE" -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $3}')
[[ "$HPA_TARGETS" == *"unknown"* ]] && fail "HPA cannot read metrics ($HPA_TARGETS) — it will never scale" || true

kubectl get pdb -n "$NAMESPACE" 2>/dev/null | grep -q "$RELEASE" && pass "PodDisruptionBudget exists" || warn "no PDB — a node drain can take out every replica at once"

if command -v helm >/dev/null 2>&1; then
  REVS=$(helm history "$RELEASE" -n "$NAMESPACE" 2>/dev/null | grep -c '^[0-9]' || true)
  [[ "${REVS:-0}" -gt 1 ]] \
    && pass "$REVS Helm revisions — a rollback target exists" \
    || warn "only $REVS revision — THERE IS NOTHING TO ROLL BACK TO"
fi

# ===========================================================================
section "7. OBSERVABILITY"
# ===========================================================================
METRICS=$(curl -s --max-time 5 "http://127.0.0.1:${PF_PORT}/metrics" 2>/dev/null | grep -c '^http_requests_total' || true)
[[ "${METRICS:-0}" -gt 0 ]] && pass "/metrics is exposing request counters" || fail "/metrics returned nothing usable"

# --tail is applied PER POD, so with N pods the sample is up to N*20 lines.
# Report the real denominator rather than a misleading "of the last 20".
LOG_SAMPLE=$(kubectl logs -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" --tail=20 2>/dev/null | grep -c . || true)
LOGLINES=$(kubectl logs -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" --tail=20 2>/dev/null | grep -c '^{' || true)
[[ "${LOGLINES:-0}" -gt 0 ]] \
  && pass "logs are structured JSON (${LOGLINES}/${LOG_SAMPLE:-0} sampled lines)" \
  || warn "logs are not JSON — Cloud Logging cannot index the fields, so field-based queries will not work"

kubectl top pods -n "$NAMESPACE" >/dev/null 2>&1 && pass "metrics-server is serving pod metrics" || fail "kubectl top does not work — HPA and dashboards are blind"

# ===========================================================================
echo
echo "========================================================================"
echo " RESULT:  ${GREEN}${PASS_N} passed${NC}   ${YELLOW}${WARN_N} warnings${NC}   ${RED}${FAIL_N} failed${NC}"
echo "========================================================================"
if [[ "$FAIL_N" -eq 0 && "$WARN_N" -eq 0 ]]; then
  echo "${GREEN} GO — migration validated. Record this output as evidence in GO_NO_GO.md.${NC}"
  exit 0
elif [[ "$FAIL_N" -eq 0 ]]; then
  echo "${YELLOW} CONDITIONAL GO — no failures, but $WARN_N warning(s) need an owner and a date.${NC}"
  exit 0
else
  echo "${RED} NO-GO — $FAIL_N check(s) failed. Do not declare the migration complete.${NC}"
  echo " Consider rolling back: ./scripts/rollback.sh -n $NAMESPACE"
  exit 1
fi

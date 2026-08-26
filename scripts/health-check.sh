#!/usr/bin/env bash
#
# health-check.sh - the 60-second "is production healthy?" sweep.
#
# This is what you run when someone asks "is everything OK?" and you need a
# defensible answer rather than a feeling. It checks the five things that
# actually determine whether users are being served.
#
# Usage: ./scripts/health-check.sh -n orders -r orders-api

set -uo pipefail

NAMESPACE="orders"
RELEASE="orders-api"
PF_PORT=18097

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
FAIL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release) RELEASE="$2"; shift 2 ;;
    -h|--help) echo "Usage: health-check.sh [-n NS] [-r RELEASE]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

ok()  { printf '%s  OK  %s %s\n' "$GREEN" "$NC" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '%s FAIL %s %s\n' "$RED" "$NC" "$1"; }
note() { printf '       %s\n' "$1"; }

echo "======================================================================"
echo " HEALTH CHECK  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo " context: $(kubectl config current-context 2>/dev/null || echo none)"
echo " target : $RELEASE in $NAMESPACE"
echo "======================================================================"

# 1. Can we reach the control plane at all? Everything below is meaningless
#    if this fails, so it is checked first.
printf '\n%s[1] Kubernetes API reachable%s\n' "$BLUE" "$NC"
if kubectl cluster-info >/dev/null 2>&1; then
  ok "API server responding"
else
  bad "cannot reach the API server"
  note "gcloud container clusters get-credentials CLUSTER --zone ZONE --project PROJECT"
  exit 1
fi

# 2. Nodes. A NotReady node silently reduces capacity; pods on it are stale.
printf '\n%s[2] Nodes%s\n' "$BLUE" "$NC"
TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv ' Ready' || true)
if [[ "${NOT_READY:-0}" -eq 0 ]]; then
  ok "$TOTAL_NODES/$TOTAL_NODES nodes Ready"
else
  bad "$NOT_READY of $TOTAL_NODES nodes are NOT Ready"
  kubectl get nodes --no-headers 2>/dev/null | grep -v ' Ready' | sed 's/^/       /'
fi

# 3. Deployment: desired vs available. This is the single number that says
#    whether you have the capacity you think you have.
printf '\n%s[3] Deployment replicas%s\n' "$BLUE" "$NC"
DESIRED=$(kubectl get deploy "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
AVAILABLE=$(kubectl get deploy "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
if [[ -z "$DESIRED" ]]; then
  bad "Deployment $RELEASE not found in $NAMESPACE"
elif [[ "${AVAILABLE:-0}" -eq "$DESIRED" ]]; then
  ok "$AVAILABLE/$DESIRED replicas available"
elif [[ "${AVAILABLE:-0}" -eq 0 ]]; then
  bad "0/$DESIRED replicas available - THE SERVICE IS DOWN"
  note "./scripts/verify-pods.sh -n $NAMESPACE"
else
  bad "only ${AVAILABLE:-0}/$DESIRED replicas available - degraded capacity"
fi

# 4. Endpoints. Pods can be Running while the Service routes to nothing.
printf '\n%s[4] Service endpoints%s\n' "$BLUE" "$NC"
EP=$(kubectl get endpoints "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
EP_COUNT=$(echo "$EP" | wc -w)
if [[ "$EP_COUNT" -gt 0 ]]; then
  ok "$EP_COUNT endpoint(s) behind the Service"
else
  bad "ZERO endpoints - the Service accepts traffic and drops it"
  note "Either no pod matches the selector, or no matching pod is Ready."
fi

# 5. Restarts in the last window.
printf '\n%s[5] Restarts%s\n' "$BLUE" "$NC"
RESTARTS=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null \
  | awk '{s+=$1} END {print s+0}')
if [[ "${RESTARTS:-0}" -eq 0 ]]; then
  ok "no restarts"
else
  bad "$RESTARTS restart(s) across the fleet"
  note "kubectl logs -n $NAMESPACE -l app.kubernetes.io/instance=$RELEASE --previous --tail=50"
fi

# 6. The application's own opinion. Everything above can be green while the
#    app itself is failing every request.
printf '\n%s[6] Application endpoints%s\n' "$BLUE" "$NC"
kubectl port-forward -n "$NAMESPACE" "svc/$RELEASE" "${PF_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
trap '[[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 3

for ep in /health /ready /version; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PF_PORT}${ep}" 2>/dev/null || echo 000)
  if [[ "$code" == "200" ]]; then ok "$ep -> 200"; else bad "$ep -> $code"; fi
done

VER=$(curl -s --max-time 5 "http://127.0.0.1:${PF_PORT}/version" 2>/dev/null \
  | grep -o '"application_version":"[^"]*"' | cut -d'"' -f4 || true)
[[ -n "$VER" ]] && note "running version: $VER"

# 7. Real request success rate. Probes returning 200 does not mean business
#    endpoints work - that gap is exactly the HTTP 500 incident scenario.
printf '\n%s[7] Business endpoint success rate (20 requests)%s\n' "$BLUE" "$NC"
SUCCESS=0
for _ in $(seq 1 20); do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PF_PORT}/api/orders" 2>/dev/null || echo 000)
  [[ "$c" == "200" ]] && SUCCESS=$((SUCCESS+1))
done
RATE=$((SUCCESS * 100 / 20))
if [[ "$RATE" -eq 100 ]]; then
  ok "20/20 succeeded (100%)"
elif [[ "$RATE" -ge 95 ]]; then
  bad "$SUCCESS/20 succeeded (${RATE}%) - a real error rate, investigate"
else
  bad "$SUCCESS/20 succeeded (${RATE}%) - USERS ARE SEEING ERRORS"
  note "docs/INCIDENT_HTTP_500.md walks the whole request path."
fi

echo
echo "======================================================================"
if [[ "$FAIL" -eq 0 ]]; then
  echo "${GREEN} HEALTHY - all checks passed.${NC}"
else
  echo "${RED} $FAIL CHECK(S) FAILED. Start with TROUBLESHOOTING.md.${NC}"
fi
echo "======================================================================"
exit $(( FAIL > 0 ? 1 : 0 ))

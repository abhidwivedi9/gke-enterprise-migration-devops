#!/usr/bin/env bash
#
# load-test.sh - generate just enough load to make the HPA scale, and no more.
#
# Deliberately lightweight. The goal is to OBSERVE autoscaling behaviour, not to
# find the breaking point. On GKE, a heavy load test scales up nodes and costs
# real money; this one stays inside a single small node's capacity.
#
# Usage:
#   ./scripts/load-test.sh -n orders -d 180 -c 20
#   ./scripts/load-test.sh --watch          # just watch the HPA, generate nothing

set -uo pipefail

NAMESPACE="orders"
RELEASE="orders-api"
DURATION=180
CONCURRENCY=20
PF_PORT=18096
WATCH_ONLY=false

GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release) RELEASE="$2"; shift 2 ;;
    -d|--duration) DURATION="$2"; shift 2 ;;
    -c|--concurrency) CONCURRENCY="$2"; shift 2 ;;
    --watch) WATCH_ONLY=true; shift ;;
    -h|--help) echo "Usage: load-test.sh [-n NS] [-d SECONDS] [-c CONCURRENCY] [--watch]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

echo "======================================================================"
echo " HPA LOAD TEST"
echo "   namespace   : $NAMESPACE"
echo "   duration    : ${DURATION}s"
echo "   concurrency : $CONCURRENCY"
echo "======================================================================"

echo
echo "--- HPA before ---"
kubectl get hpa "$RELEASE" -n "$NAMESPACE" 2>/dev/null || echo "no HPA found"
kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" --no-headers 2>/dev/null | wc -l | xargs echo "pods:"

if [[ "$WATCH_ONLY" == true ]]; then
  echo
  echo "Watching (Ctrl-C to stop). Generating no load."
  kubectl get hpa "$RELEASE" -n "$NAMESPACE" -w
  exit 0
fi

kubectl port-forward -n "$NAMESPACE" "svc/$RELEASE" "${PF_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
cleanup() {
  [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true
  jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT
sleep 3

# CPU_BURN is enabled on the app for this run so a modest request rate produces
# measurable CPU. Without it you would need thousands of req/s to move the HPA -
# which on GKE would mean scaling nodes and paying for them.
echo
echo "${YELLOW}Enabling CPU_BURN on the deployment so modest traffic registers as load.${NC}"
kubectl set env "deployment/$RELEASE" -n "$NAMESPACE" CPU_BURN=true >/dev/null 2>&1
kubectl rollout status "deployment/$RELEASE" -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1

echo
echo "--- generating load for ${DURATION}s ---"
END=$(( $(date +%s) + DURATION ))
for _ in $(seq 1 "$CONCURRENCY"); do
  (
    while [[ $(date +%s) -lt $END ]]; do
      curl -s -o /dev/null --max-time 5 "http://127.0.0.1:${PF_PORT}/api/orders" 2>/dev/null || true
    done
  ) &
done

# Sample the HPA every 15s so the scale-up is visible as it happens.
while [[ $(date +%s) -lt $END ]]; do
  line="$(kubectl get hpa "$RELEASE" -n "$NAMESPACE" --no-headers 2>/dev/null || true)"
  pods="$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" --no-headers 2>/dev/null | wc -l)"
  printf '%s  [%ss left] pods=%s | %s%s\n' "$BLUE" "$(( END - $(date +%s) ))" "$pods" "$line" "$NC"
  sleep 15
done

wait 2>/dev/null || true

echo
echo "--- HPA after ---"
kubectl get hpa "$RELEASE" -n "$NAMESPACE"
kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE"
echo
echo "--- scaling decisions (the 'why') ---"
kubectl describe hpa "$RELEASE" -n "$NAMESPACE" 2>/dev/null | tail -15

echo
echo "${YELLOW}Disabling CPU_BURN.${NC}"
kubectl set env "deployment/$RELEASE" -n "$NAMESPACE" CPU_BURN- >/dev/null 2>&1

cat <<EOF

======================================================================
${GREEN} LOAD TEST COMPLETE${NC}

 What to notice:
   * Scale-UP is fast (30s stabilisation window in values.yaml).
   * Scale-DOWN is slow (300s) and that is deliberate - it stops the HPA
     flapping on brief traffic dips.
   * Utilisation is measured against the CPU REQUEST (50m), not the limit
     and not the node. 70% of 50m is 35m.

 If it did NOT scale, work through these in order:
   1. kubectl top pods -n $NAMESPACE          <- no metrics = metrics-server
   2. kubectl describe hpa $RELEASE -n $NAMESPACE  <- read the conditions
   3. Is resources.requests.cpu set? Without it, HPA cannot compute a ratio.
   4. Did it already hit maxReplicas?
   5. Are new pods stuck Pending? Scaling is capped by cluster capacity.
======================================================================
EOF

#!/usr/bin/env bash
#
# verify-pods.sh — the "check the pods" command, done properly.
#
# When someone says "pods are restarting" or "check why this pod is not ready",
# this is the sweep. It does not just print `kubectl get pods`; it classifies
# every unhealthy state it finds and tells you the next command for each one.
#
# Usage:
#   ./scripts/verify-pods.sh -n orders
#   ./scripts/verify-pods.sh -n orders -l app.kubernetes.io/instance=orders-api

set -uo pipefail

NAMESPACE="orders"
SELECTOR=""

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
ISSUES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -l|--selector) SELECTOR="$2"; shift 2 ;;
    -h|--help) echo "Usage: verify-pods.sh [-n NAMESPACE] [-l SELECTOR]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

SEL_ARGS=()
[[ -n "$SELECTOR" ]] && SEL_ARGS=(-l "$SELECTOR")

section() { printf '\n%s=== %s ===%s\n' "$BLUE" "$1" "$NC"; }
problem() { ISSUES=$((ISSUES+1)); printf '%s  ! %s%s\n' "$RED" "$1" "$NC"; }
advise()  { printf '      -> %s\n' "$1"; }

echo "========================================================================"
echo " POD HEALTH — namespace: $NAMESPACE  $( [[ -n "$SELECTOR" ]] && echo "selector: $SELECTOR")"
echo " context: $(kubectl config current-context 2>/dev/null || echo '<none>')"
echo "========================================================================"

section "Overview"
kubectl get pods -n "$NAMESPACE" "${SEL_ARGS[@]}" -o wide 2>/dev/null || {
  echo "${RED}Cannot list pods in $NAMESPACE.${NC}"; exit 1; }

# ---------------------------------------------------------------------------
# Not-Running phases.
# ---------------------------------------------------------------------------
section "Pods not in Running phase"
NOT_RUNNING="$(kubectl get pods -n "$NAMESPACE" "${SEL_ARGS[@]}" \
  --field-selector=status.phase!=Running -o name 2>/dev/null || true)"
if [[ -z "$NOT_RUNNING" ]]; then
  echo "${GREEN}  none${NC}"
else
  while read -r p; do
    [[ -z "$p" ]] && continue
    name="${p#pod/}"
    phase="$(kubectl get "$p" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)"
    problem "$name is $phase"
    case "$phase" in
      Pending)
        # Pending means the SCHEDULER could not place it. The reason is always
        # in the pod's events, never in the container logs (there is no
        # container yet).
        advise "kubectl describe pod $name -n $NAMESPACE | tail -20"
        advise "Usual causes: insufficient CPU/memory, node selector or taint mismatch, unbound PVC"
        kubectl get events -n "$NAMESPACE" --field-selector "involvedObject.name=${name}" \
          -o custom-columns=REASON:.reason,MSG:.message --no-headers 2>/dev/null | tail -3 | sed 's/^/         /'
        ;;
      Failed)
        advise "kubectl describe pod $name -n $NAMESPACE"
        advise "kubectl logs $name -n $NAMESPACE --previous" ;;
      *)
        advise "kubectl describe pod $name -n $NAMESPACE" ;;
    esac
  done <<< "$NOT_RUNNING"
fi

# ---------------------------------------------------------------------------
# Running but NOT Ready — the state that causes "the deploy succeeded but the
# service is down". The container is up; readiness is failing; the Service has
# removed it from Endpoints.
# ---------------------------------------------------------------------------
section "Running but NOT Ready (readiness failing)"
FOUND_NOTREADY=false
while IFS='|' read -r name ready phase; do
  [[ -z "$name" ]] && continue
  if [[ "$phase" == "Running" && "${ready,,}" != "true" ]]; then
    FOUND_NOTREADY=true
    problem "$name is Running but not Ready"
    advise "It is receiving NO traffic — the Service has dropped it from Endpoints."
    advise "kubectl describe pod $name -n $NAMESPACE | grep -A5 Readiness"
    advise "kubectl logs $name -n $NAMESPACE --tail=50"
  fi
done <<< "$(kubectl get pods -n "$NAMESPACE" "${SEL_ARGS[@]}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"|"}{.status.phase}{"\n"}{end}' 2>/dev/null)"
[[ "$FOUND_NOTREADY" == false ]] && echo "${GREEN}  none${NC}"

# ---------------------------------------------------------------------------
# Restarts, with the termination reason — which is what actually identifies the
# problem. RESTARTS: 7 tells you nothing; "OOMKilled, exit 137" tells you
# everything.
# ---------------------------------------------------------------------------
section "Restarts and last termination reason"
FOUND_RESTARTS=false
while IFS='|' read -r name restarts reason exitcode; do
  [[ -z "$name" ]] && continue
  if [[ "${restarts:-0}" -gt 0 ]]; then
    FOUND_RESTARTS=true
    problem "$name has restarted ${restarts}x — last: ${reason:-unknown} (exit ${exitcode:-?})"
    case "${reason:-}" in
      OOMKilled)
        advise "Exit 137 = the kernel killed it for exceeding its memory LIMIT."
        advise "This is not a leak by itself: the limit may simply be too low."
        advise "kubectl get pod $name -n $NAMESPACE -o jsonpath='{.spec.containers[0].resources}'"
        advise "Fix: raise resources.limits.memory, or fix the allocation." ;;
      Error)
        advise "The application exited non-zero. The reason is in the PREVIOUS container's logs:"
        advise "kubectl logs $name -n $NAMESPACE --previous --tail=100" ;;
      Completed)
        advise "Exit 0 — the process ended cleanly. For a long-running service that is still a bug." ;;
      *)
        advise "kubectl logs $name -n $NAMESPACE --previous --tail=100" ;;
    esac
  fi
done <<< "$(kubectl get pods -n "$NAMESPACE" "${SEL_ARGS[@]}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.containerStatuses[0].restartCount}{"|"}{.status.containerStatuses[0].lastState.terminated.reason}{"|"}{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}{end}' 2>/dev/null)"
[[ "$FOUND_RESTARTS" == false ]] && echo "${GREEN}  no restarts${NC}"

# ---------------------------------------------------------------------------
# Waiting reasons — CrashLoopBackOff, ImagePullBackOff, CreateContainerConfigError.
# ---------------------------------------------------------------------------
section "Containers stuck in a waiting state"
FOUND_WAITING=false
while IFS='|' read -r name reason message; do
  [[ -z "$name" || -z "$reason" ]] && continue
  FOUND_WAITING=true
  problem "$name: $reason"
  [[ -n "$message" ]] && advise "${message:0:160}"
  case "$reason" in
    CrashLoopBackOff)
      advise "The container starts, exits, and kubelet backs off (10s,20s,40s... capped at 5m)."
      advise "kubectl logs $name -n $NAMESPACE --previous   <-- the crash is HERE, not in current logs" ;;
    ImagePullBackOff|ErrImagePull)
      advise "The kubelet cannot pull the image. Check, in order:"
      advise "  1. the tag exists:  gcloud artifacts docker images list REPO"
      advise "  2. the node SA has roles/artifactregistry.reader"
      advise "  3. the registry path in the Deployment is spelled correctly"
      advise "  4. on kind: did you run 'kind load docker-image'?" ;;
    CreateContainerConfigError)
      advise "A referenced ConfigMap or Secret KEY does not exist."
      advise "kubectl describe pod $name -n $NAMESPACE | tail -15" ;;
    ContainerCreating)
      advise "Usually transient. If it persists: volume mount or image pull is stuck." ;;
  esac
done <<< "$(kubectl get pods -n "$NAMESPACE" "${SEL_ARGS[@]}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.containerStatuses[0].state.waiting.reason}{"|"}{.status.containerStatuses[0].state.waiting.message}{"\n"}{end}' 2>/dev/null)"
[[ "$FOUND_WAITING" == false ]] && echo "${GREEN}  none${NC}"

# ---------------------------------------------------------------------------
# Recent warning events — often the fastest path to the answer.
# ---------------------------------------------------------------------------
section "Recent Warning events"
EVENTS="$(kubectl get events -n "$NAMESPACE" --field-selector type=Warning \
  --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,OBJECT:.involvedObject.name,REASON:.reason,MESSAGE:.message \
  --no-headers 2>/dev/null | tail -10 || true)"
if [[ -z "$EVENTS" ]]; then
  echo "${GREEN}  none${NC}"
else
  echo "$EVENTS" | cut -c1-170
  echo "${YELLOW}  NOTE: events expire after ~1 hour by default. If an incident is older${NC}"
  echo "${YELLOW}  than that, events are gone and you need Cloud Logging instead.${NC}"
fi

# ---------------------------------------------------------------------------
# Endpoints — the connection between Service and pods. Empty endpoints is the
# reason for a large share of "the service is down but the pods look fine".
# ---------------------------------------------------------------------------
section "Service endpoints"
for svc in $(kubectl get svc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  eps="$(kubectl get endpoints "$svc" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  if [[ -z "$eps" ]]; then
    problem "Service '$svc' has ZERO endpoints — it is a black hole for traffic."
    advise "Either no pod matches its selector, or no matching pod is Ready."
    advise "kubectl get svc $svc -n $NAMESPACE -o jsonpath='{.spec.selector}'"
  else
    echo "${GREEN}  $svc -> $(echo "$eps" | wc -w) endpoint(s)${NC}"
  fi
done

section "Resource usage"
kubectl top pods -n "$NAMESPACE" "${SEL_ARGS[@]}" 2>/dev/null \
  || echo "${YELLOW}  metrics unavailable (metrics-server not installed or not ready)${NC}"

echo
echo "========================================================================"
if [[ "$ISSUES" -eq 0 ]]; then
  echo "${GREEN} No pod-level problems found in $NAMESPACE.${NC}"
else
  echo "${RED} $ISSUES problem(s) found. Runbook: TROUBLESHOOTING.md${NC}"
fi
echo "========================================================================"
exit $(( ISSUES > 0 ? 1 : 0 ))

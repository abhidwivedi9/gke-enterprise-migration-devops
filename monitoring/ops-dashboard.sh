#!/usr/bin/env bash
#
# ops-dashboard.sh — the GKE DevOps operations dashboard, in a terminal.
#
# Every panel from the Cloud Monitoring dashboard, with no cloud account, no
# Prometheus, no Grafana and no cost. Works identically on kind and on GKE.
#
# This is not a toy substitute. During an incident it is often FASTER than a
# browser dashboard, because it is one command and it shows you the specific
# fields that matter rather than pretty graphs.
#
#   ./monitoring/ops-dashboard.sh -n orders
#   ./monitoring/ops-dashboard.sh -n orders --watch

set -uo pipefail

NAMESPACE="orders"
RELEASE="orders-api"
WATCH=false
INTERVAL=10
PF_PORT=18091

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release) RELEASE="$2"; shift 2 ;;
    --watch) WATCH=true; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    -h|--help) echo "Usage: ops-dashboard.sh [-n NS] [-r RELEASE] [--watch] [--interval SECONDS]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

panel() { printf '\n%s%s── %s %s%s\n' "$BOLD" "$BLUE" "$1" "$(printf '─%.0s' $(seq 1 $((56 - ${#1}))))" "$NC"; }
good()  { printf '   %s●%s %s\n' "$GREEN" "$NC" "$1"; }
warn()  { printf '   %s●%s %s\n' "$YELLOW" "$NC" "$1"; }
bad()   { printf '   %s●%s %s\n' "$RED" "$NC" "$1"; }
dim()   { printf '     %s%s%s\n' "$DIM" "$1" "$NC"; }

render() {
  clear 2>/dev/null || true

  printf '%s╔══════════════════════════════════════════════════════════════╗%s\n' "$BOLD" "$NC"
  printf '%s║  GKE OPERATIONS DASHBOARD — %-33s ║%s\n' "$BOLD" "$RELEASE" "$NC"
  printf '%s╚══════════════════════════════════════════════════════════════╝%s\n' "$BOLD" "$NC"
  printf '   %scontext: %s   namespace: %s   %s%s\n' "$DIM" \
    "$(kubectl config current-context 2>/dev/null || echo '<none>')" "$NAMESPACE" \
    "$(date -u '+%H:%M:%SZ')" "$NC"

  # ------------------------------------------------------------------ CLUSTER
  panel "CLUSTER HEALTH"
  local total ready
  total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
  if [[ "${ready:-0}" -eq "${total:-0}" && "${total:-0}" -gt 0 ]]; then
    good "nodes: ${ready}/${total} Ready"
  else
    bad "nodes: ${ready:-0}/${total:-0} Ready — capacity has silently dropped"
    kubectl get nodes --no-headers 2>/dev/null | grep -v ' Ready' | sed 's/^/       /'
  fi

  # Pressure conditions predict outages before they happen.
  local pressure
  pressure=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}{"\n"}{end}' 2>/dev/null \
    | grep -E 'MemoryPressure|DiskPressure|PIDPressure' || true)
  [[ -n "$pressure" ]] && bad "node pressure detected:" && echo "$pressure" | sed 's/^/       /'

  kubectl top nodes --no-headers 2>/dev/null | awk '{printf "     %-28s cpu %-8s mem %s\n", $1, $3, $5}' \
    || dim "node metrics unavailable (metrics-server)"

  # -------------------------------------------------------------- APPLICATION
  panel "APPLICATION HEALTH"
  local desired available updated
  desired=$(kubectl get deploy "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  available=$(kubectl get deploy "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
  updated=$(kubectl get deploy "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || true)
  desired="${desired:-0}"; available="${available:-0}"; updated="${updated:-0}"

  if [[ "$desired" == "0" ]]; then
    bad "deployment '$RELEASE' not found in namespace '$NAMESPACE'"
  elif [[ "$available" -eq "$desired" ]]; then
    good "replicas: ${available}/${desired} available"
  elif [[ "$available" -eq 0 ]]; then
    bad "replicas: 0/${desired} — THE SERVICE IS DOWN"
  else
    bad "replicas: ${available}/${desired} — degraded capacity"
  fi
  # updated < desired means some pods still run the OLD template right now.
  [[ "$updated" -ne "$desired" ]] && warn "only ${updated}/${desired} pods are on the current template (rollout in progress)"

  local restarts
  restarts=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null \
    | awk '{s+=$1} END {print s+0}')
  [[ "${restarts:-0}" -eq 0 ]] && good "restarts: 0" || bad "restarts: ${restarts} — kubectl logs POD --previous"

  # Bad pod states, counted.
  local pending crashing notready
  pending=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c 'Pending' || true)
  crashing=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c 'CrashLoopBackOff\|Error\|ImagePullBackOff' || true)
  notready=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -ci 'false' || true)
  [[ "${pending:-0}" -gt 0 ]]  && bad "pending: ${pending}"
  [[ "${crashing:-0}" -gt 0 ]] && bad "crashing/failed: ${crashing}"
  [[ "${notready:-0}" -gt 0 ]] && bad "not ready: ${notready} — receiving no traffic"

  echo
  kubectl get pods -n "$NAMESPACE" -o wide --no-headers 2>/dev/null \
    | awk '{printf "     %-32s %-6s %-20s %s\n", $1, $2, $3, $7}'

  # ----------------------------------------------------------------- ROUTING
  panel "TRAFFIC ROUTING"
  local eps
  eps=$(kubectl get endpoints "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  local n; n=$(echo "$eps" | wc -w)
  if [[ "$n" -gt 0 ]]; then
    good "endpoints: ${n} pod(s) behind the Service"
    [[ "$n" -lt "$desired" ]] && warn "fewer endpoints than replicas — some requests hit nothing"
  else
    bad "endpoints: ZERO — the Service accepts traffic and drops it"
  fi

  # ------------------------------------------------------------- AUTOSCALING
  panel "AUTOSCALING"
  local hpa
  # NOT --no-headers + awk positional: kubectl prints TARGETS as "cpu: 12%/70%",
  # which is TWO whitespace-separated tokens, so $3..$6 silently shift.
  hpa=$(kubectl get hpa "$RELEASE" -n "$NAMESPACE" \
    -o jsonpath='{.spec.minReplicas}{"|"}{.spec.maxReplicas}{"|"}{.status.currentReplicas}{"|"}{.status.currentMetrics[0].resource.current.averageUtilization}{"|"}{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null || true)
  if [[ -z "$hpa" ]]; then
    warn "no HPA — this workload cannot absorb a traffic spike"
  else
    IFS='|' read -r hmin hmax hcur hutil htarget <<< "$hpa"
    printf '     min %-4s max %-4s current %-4s  cpu %s%%/%s%%\n' \
      "${hmin:-?}" "${hmax:-?}" "${hcur:-?}" "${hutil:-<unknown>}" "${htarget:-?}"
    if [[ -z "$hutil" ]]; then
      bad "HPA cannot read metrics — it will NEVER scale"
      dim "kubectl top pods works? -> requests.cpu is unset.  Fails? -> metrics-server."
    else
      good "HPA is reading metrics"
    fi
  fi

  # ---------------------------------------------------------------- RESOURCES
  panel "RESOURCE USAGE"
  kubectl top pods -n "$NAMESPACE" --no-headers 2>/dev/null \
    | awk '{printf "     %-32s cpu %-8s mem %s\n", $1, $2, $3}' \
    || dim "pod metrics unavailable"

  # ------------------------------------------------------------------ VERSION
  panel "DEPLOYMENT & VERSION"
  local versions
  versions=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
    -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/version}{"\n"}{end}' 2>/dev/null | sort -u | grep -c . || true)
  if [[ "${versions:-0}" -gt 1 ]]; then
    bad "MIXED FLEET — ${versions} different versions serving simultaneously"
    dim "this is what 'intermittent' bugs usually are"
  fi
  kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" \
    -o jsonpath='{range .items[*]}{"     "}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null

  if command -v helm >/dev/null 2>&1; then
    echo
    helm list -n "$NAMESPACE" --no-headers 2>/dev/null \
      | awk '{printf "     release %-14s rev %-4s %-12s appVersion %s\n", $1, $3, $8, $10}'
  fi

  # ------------------------------------------------------------- ERROR RATE
  panel "REQUEST SUCCESS RATE  (live sample)"
  kubectl port-forward -n "$NAMESPACE" "svc/$RELEASE" "${PF_PORT}:80" >/dev/null 2>&1 &
  local pf=$!
  sleep 2
  local ok=0 err=0 code
  for _ in $(seq 1 20); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PF_PORT}/api/orders" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]] && ok=$((ok+1)) || err=$((err+1))
  done
  local ver
  ver=$(curl -s --max-time 3 "http://127.0.0.1:${PF_PORT}/version" 2>/dev/null \
        | grep -o '"application_version":"[^"]*"' | cut -d'"' -f4 || true)
  kill "$pf" 2>/dev/null || true

  if [[ "$err" -eq 0 ]]; then
    good "20/20 requests succeeded (100%)"
  else
    bad "$ok/20 succeeded — USERS ARE SEEING ERRORS ($(( err * 100 / 20 ))% failing)"
    dim "probes can be green while this is red -> docs/INCIDENT_HTTP_500.md"
  fi
  [[ -n "$ver" ]] && dim "/version reports: $ver"

  # ------------------------------------------------------------------ EVENTS
  panel "RECENT WARNINGS"
  local ev
  ev=$(kubectl get events -n "$NAMESPACE" --field-selector type=Warning \
        --sort-by=.lastTimestamp --no-headers 2>/dev/null | tail -5 || true)
  if [[ -z "$ev" ]]; then
    good "none"
  else
    echo "$ev" | cut -c1-110 | sed 's/^/     /'
    dim "events expire after ~1h — ./scripts/collect-logs.sh -n $NAMESPACE to keep them"
  fi

  echo
  printf '   %s./scripts/health-check.sh · ./scripts/verify-pods.sh · TROUBLESHOOTING.md%s\n' "$DIM" "$NC"
}

if [[ "$WATCH" == true ]]; then
  trap 'echo; echo "stopped."; exit 0' INT
  while true; do
    render
    printf '\n   %srefreshing every %ss — Ctrl-C to stop%s\n' "$DIM" "$INTERVAL" "$NC"
    sleep "$INTERVAL"
  done
else
  render
fi

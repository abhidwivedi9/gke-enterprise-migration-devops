#!/usr/bin/env bash
#
# run.sh — the failure lab.
#
# Fifteen controlled failures you can inject into a running deployment, observe,
# diagnose and fix. Every one reproduces a real production incident.
#
# The rule while using this: DIAGNOSE BEFORE YOU READ THE ANSWER. The value is
# entirely in the minutes you spend not knowing. `run.sh explain N` is there for
# afterwards, and README.md has the full write-up for each scenario.
#
#   ./failure-lab/run.sh list
#   ./failure-lab/run.sh start 01
#   ./failure-lab/run.sh status
#   ./failure-lab/run.sh explain 01
#   ./failure-lab/run.sh reset
#
# Everything runs against the LOCAL kind cluster by default and costs nothing.

set -uo pipefail

NAMESPACE="${LAB_NAMESPACE:-orders}"
RELEASE="${LAB_RELEASE:-orders-api}"
CHART="helm/application"
VALUES=(-f helm/application/values.yaml -f helm/application/values-local.yaml)

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'

cd "$(dirname "$0")/.." || { echo "cannot cd to repo root" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Scenario catalogue: id|title|what breaks
# ---------------------------------------------------------------------------
scenario_title() {
  case "$1" in
    01) echo "CrashLoopBackOff — container exits non-zero on boot" ;;
    02) echo "ImagePullBackOff — the tag does not exist" ;;
    03) echo "Pending pod — no node has enough CPU" ;;
    04) echo "OOMKilled — memory limit is below actual usage" ;;
    05) echo "Readiness failure — Running, Ready 0/1, zero endpoints" ;;
    06) echo "Liveness too aggressive — healthy app restarted in a loop" ;;
    07) echo "Startup probe too short — slow boot killed before it finishes" ;;
    08) echo "Missing Secret — required config absent, fail-fast on boot" ;;
    09) echo "Wrong ConfigMap value — deploys clean, behaves wrong" ;;
    10) echo "Wrong version live — Helm says 2.4.18, pods serve 2.4.17" ;;
    11) echo "PDB blocks drain — node cordon/drain hangs forever" ;;
    12) echo "Workload Identity 403 — KSA/GSA binding mismatch (GKE only)" ;;
    13) echo "HPA will not scale — no CPU request, metrics <unknown>" ;;
    14) echo "Service has no endpoints — selector does not match any pod" ;;
    15) echo "Bad release — elevated HTTP 500s, requires rollback" ;;
    *) echo "unknown scenario" ;;
  esac
}

usage() {
  cat <<USAGE
${BOLD}FAILURE LAB${NC}

  ./failure-lab/run.sh list            show all scenarios
  ./failure-lab/run.sh start ID        inject a failure
  ./failure-lab/run.sh status          what is currently broken
  ./failure-lab/run.sh explain ID      the answer (read AFTER you have tried)
  ./failure-lab/run.sh reset           restore a healthy deployment

  namespace: $NAMESPACE   release: $RELEASE
  override with LAB_NAMESPACE / LAB_RELEASE
USAGE
}

list_scenarios() {
  echo
  echo "${BOLD}FAILURE LAB — 15 scenarios${NC}"
  echo "----------------------------------------------------------------------"
  for id in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15; do
    printf "  %s%s%s  %s\n" "$BOLD" "$id" "$NC" "$(scenario_title "$id")"
  done
  echo "----------------------------------------------------------------------"
  echo "  start with:  ./failure-lab/run.sh start 01"
  echo "  full write-ups (symptom -> root cause -> fix -> interview question):"
  echo "               failure-lab/README.md"
  echo
}

require_release() {
  if ! kubectl get deployment "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "${RED}No deployment '$RELEASE' in namespace '$NAMESPACE'.${NC}" >&2
    echo "Bring the stack up first:  ./scripts/local-up.sh" >&2
    exit 1
  fi
}

helm_set() {
  # --force-conflicts: Helm 4 applies via Server-Side Apply by default, so any
  # field a raw `kubectl` command has ever touched on this object (kubectl set
  # image, kubectl annotate, kubectl patch - several scenarios below use these
  # deliberately) is now owned by a different field manager, and a plain
  # `helm upgrade` is REJECTED as a conflict rather than applied. The lab
  # exists to inject faults via kubectl AND Helm side by side, so Helm must be
  # told to reclaim ownership every time, or every scenario after the first
  # kubectl mutation silently stops applying its fault.
  helm upgrade "$RELEASE" "$CHART" "${VALUES[@]}" -n "$NAMESPACE" --reuse-values --force-conflicts "$@"
}

banner() {
  echo
  echo "${YELLOW}======================================================================${NC}"
  echo "${YELLOW} SCENARIO $1 INJECTED${NC}"
  echo "${YELLOW} $(scenario_title "$1")${NC}"
  echo "${YELLOW}======================================================================${NC}"
  echo
  echo "${BOLD}Your turn. Diagnose it before reading anything.${NC}"
  echo
  echo "  Start here:"
  echo "    kubectl get pods -n $NAMESPACE"
  echo "    ./scripts/verify-pods.sh -n $NAMESPACE"
  echo
  echo "  When you are done (or genuinely stuck):"
  echo "    ./failure-lab/run.sh explain $1"
  echo "    ./failure-lab/run.sh reset"
  echo
}

start_scenario() {
  local id="$1"
  require_release

  case "$id" in
    01)
      # The app exits 1 during startup. kubelet restarts it, it exits again,
      # and the backoff grows 10s -> 20s -> 40s ... capped at 5 minutes.
      helm_set --set faultInjection.crashOnStart=true --timeout 90s --wait=false
      ;;
    02)
      # A tag that was never built. Nothing about the cluster is wrong; the
      # registry simply has no such image.
      kubectl set image "deployment/$RELEASE" "$RELEASE=orders-api:9.9.9-does-not-exist" -n "$NAMESPACE"
      ;;
    03)
      # Request more CPU than any node can offer. The scheduler cannot place the
      # pod, so it sits Pending with no container and therefore no logs.
      kubectl patch "deployment/$RELEASE" -n "$NAMESPACE" --type=json \
        -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"64"}]'
      ;;
    04)
      # Allocate 200MB inside a 128Mi limit. The kernel OOM-kills it: exit 137.
      helm_set --set faultInjection.memoryBallastMb=200 --timeout 90s --wait=false
      ;;
    05)
      # /ready returns 503 while /health still returns 200. The container keeps
      # running (liveness passes) but is pulled out of the Service.
      helm_set --set faultInjection.failReadiness=true --timeout 90s --wait=false
      ;;
    06)
      # /health returns 500. Liveness fails, kubelet restarts the container, and
      # the restart count climbs even though the app itself is fine.
      helm_set --set faultInjection.failLiveness=true --timeout 90s --wait=false
      ;;
    07)
      # Boot takes 90s; the startup probe allows 30 x 2s = 60s. It is killed
      # mid-boot, forever.
      helm_set --set faultInjection.startupDelaySeconds=90 \
               --set probes.startup.failureThreshold=10 --timeout 90s --wait=false
      ;;
    08)
      # Point at a Secret that does not exist. The app fail-fasts on the missing
      # required key and says so in its logs.
      helm_set --set secrets.create=false \
               --set secrets.existingSecret=orders-api-secrets-typo --timeout 90s --wait=false
      ;;
    09)
      # A config value that is syntactically fine and semantically wrong. The
      # deploy is completely green; only behaviour changes.
      helm_set --set config.LOG_LEVEL=CRITICAL \
               --set config.SHUTDOWN_DRAIN_SECONDS=0 --timeout 120s --wait=false
      ;;
    10)
      # Bump the Helm appVersion WITHOUT changing the image. Helm reports 2.4.18;
      # every pod still serves 2.4.17. This is the whole reason
      # scripts/verify-version.sh exists.
      # The image stays on 2.4.17 while every human-readable signal claims 2.4.18.
      helm_set --set image.tag=2.4.17 --timeout 120s --wait=false
      kubectl annotate "deployment/$RELEASE" -n "$NAMESPACE" \
        "kubernetes.io/change-cause=helm upgrade to appVersion 2.4.18" --overwrite
      echo "${YELLOW}The change-cause now claims 2.4.18. The image does not.${NC}"
      echo "${YELLOW}Prove which one is lying.${NC}"
      ;;
    11)
      # minAvailable == replicas. Every eviction is refused, so a drain never
      # completes and cluster upgrades stall.
      helm_set --set podDisruptionBudget.minAvailable=2 \
               --set autoscaling.enabled=false --set replicaCount=2 --timeout 120s
      echo "${YELLOW}Now try to drain a node and watch it hang:${NC}"
      echo "  kubectl drain \$(kubectl get pods -n $NAMESPACE -o jsonpath='{.items[0].spec.nodeName}') \\"
      echo "    --ignore-daemonsets --delete-emptydir-data --timeout=60s"
      ;;
    12)
      # GKE only: annotate the KSA with a GSA that has no matching IAM binding.
      kubectl annotate sa "$RELEASE" -n "$NAMESPACE" \
        "iam.gke.io/gcp-service-account=wrong-sa@wrong-project.iam.gserviceaccount.com" --overwrite
      kubectl rollout restart "deployment/$RELEASE" -n "$NAMESPACE"
      echo "${YELLOW}NOTE: this only produces a real 403 on GKE. On kind there is no${NC}"
      echo "${YELLOW}metadata server, so study the binding itself rather than the error.${NC}"
      ;;
    13)
      # Remove the CPU request. Utilisation is a percentage OF the request, so
      # with no request the HPA cannot compute anything and reports <unknown>.
      kubectl patch "deployment/$RELEASE" -n "$NAMESPACE" --type=json \
        -p='[{"op":"remove","path":"/spec/template/spec/containers/0/resources/requests/cpu"}]' 2>/dev/null \
        || echo "(cpu request already absent)"
      ;;
    14)
      # Change the Service selector so it matches nothing. The pods stay
      # perfectly healthy; the Service becomes a black hole.
      kubectl patch "svc/$RELEASE" -n "$NAMESPACE" --type=merge \
        -p='{"spec":{"selector":{"app.kubernetes.io/name":"orders-api-typo","app.kubernetes.io/instance":"orders-api"}}}'
      ;;
    15)
      # 30% of business requests return 500. Probes stay green, so Kubernetes is
      # perfectly happy and users are not.
      helm_set --set faultInjection.errorRatePercent=30 --timeout 120s
      echo "${YELLOW}Users are now seeing intermittent 500s. Probes are all green.${NC}"
      ;;
    *)
      echo "${RED}Unknown scenario '$id'. Try: ./failure-lab/run.sh list${NC}" >&2
      exit 2 ;;
  esac

  echo "$id" > .failure-lab-active
  banner "$id"
}

show_status() {
  echo
  if [[ -f .failure-lab-active ]]; then
    local id; id="$(cat .failure-lab-active)"
    echo "${YELLOW}ACTIVE SCENARIO: $id — $(scenario_title "$id")${NC}"
  else
    echo "${GREEN}No scenario active.${NC}"
  fi
  echo
  echo "--- pods ---"
  kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null
  echo
  echo "--- deployment ---"
  kubectl get deploy "$RELEASE" -n "$NAMESPACE" 2>/dev/null
  echo
  echo "--- endpoints ---"
  kubectl get endpoints "$RELEASE" -n "$NAMESPACE" 2>/dev/null
  echo
  echo "--- recent warnings ---"
  kubectl get events -n "$NAMESPACE" --field-selector type=Warning \
    --sort-by=.lastTimestamp --no-headers 2>/dev/null | tail -6 | cut -c1-150
  echo
}

explain() {
  local id="$1"
  echo
  echo "${BLUE}======================================================================${NC}"
  echo "${BOLD} SCENARIO $id — $(scenario_title "$id")${NC}"
  echo "${BLUE}======================================================================${NC}"
  # The full write-up lives in README.md so there is exactly one copy of it.
  awk -v pat="^## $id " '
    $0 ~ pat {p=1}
    p && /^## / && $0 !~ pat {exit}
    p {print}
  ' failure-lab/README.md
  echo
}

reset_lab() {
  require_release
  echo "Restoring a healthy deployment..."

  # Undo the kubectl-level edits that Helm does not own.
  kubectl patch "svc/$RELEASE" -n "$NAMESPACE" --type=merge \
    -p='{"spec":{"selector":{"app.kubernetes.io/name":"orders-api","app.kubernetes.io/instance":"'"$RELEASE"'"}}}' >/dev/null 2>&1 || true
  kubectl annotate sa "$RELEASE" -n "$NAMESPACE" "iam.gke.io/gcp-service-account-" >/dev/null 2>&1 || true

  # --reset-values discards every accumulated --set from previous scenarios and
  # re-renders purely from the values files. Without it, scenario 4's ballast
  # would still be set while you are trying to reproduce scenario 9.
  helm upgrade "$RELEASE" "$CHART" "${VALUES[@]}" -n "$NAMESPACE" \
    --reset-values --wait --timeout 5m

  rm -f .failure-lab-active
  echo
  echo "${GREEN}Reset complete.${NC}"
  kubectl get pods -n "$NAMESPACE"
  echo
  echo "Confirm with: ./scripts/health-check.sh -n $NAMESPACE"
}

case "${1:-}" in
  list) list_scenarios ;;
  start) [[ -n "${2:-}" ]] || { echo "usage: run.sh start ID" >&2; exit 2; }; start_scenario "$2" ;;
  status) show_status ;;
  explain) [[ -n "${2:-}" ]] || { echo "usage: run.sh explain ID" >&2; exit 2; }; explain "$2" ;;
  reset) reset_lab ;;
  *) usage ;;
esac

#!/usr/bin/env bash
#
# collect-logs.sh — capture everything about an incident BEFORE the evidence
# disappears.
#
# WHY THE TIMING MATTERS. Kubernetes deletes evidence aggressively:
#   * events are garbage collected after ~1 hour
#   * `kubectl logs --previous` only holds the LAST terminated container; a
#     second restart overwrites it
#   * deleting or scaling a Deployment destroys the pods and their logs with it
#
# So this runs FIRST, before you start fixing. Fixing destroys evidence.
#
# Usage:
#   ./scripts/collect-logs.sh -n orders
#   ./scripts/collect-logs.sh -n orders --since 30m

set -uo pipefail

NAMESPACE="orders"
SINCE="1h"
OUTPUT_DIR=""

GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) echo "Usage: collect-logs.sh [-n NS] [--since 1h] [-o DIR]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

TS="$(date -u '+%Y%m%dT%H%M%SZ')"
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="logs-bundle-${NAMESPACE}-${TS}"
mkdir -p "$OUTPUT_DIR"

say() { printf '%s  -> %s%s\n' "$BLUE" "$1" "$NC"; }

echo "========================================================================"
echo " EVIDENCE COLLECTION"
echo "   namespace : $NAMESPACE"
echo "   window    : last $SINCE"
echo "   output    : $OUTPUT_DIR/"
echo "========================================================================"

# ---------------------------------------------------------------------------
# Context: which cluster, when, as whom. An incident bundle without this is
# ambiguous the moment more than one cluster exists.
# ---------------------------------------------------------------------------
{
  echo "collected_at      : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "kubectl_context   : $(kubectl config current-context 2>/dev/null)"
  echo "namespace         : $NAMESPACE"
  echo "collected_by      : $(whoami 2>/dev/null || echo unknown)"
  echo
  kubectl version -o yaml 2>/dev/null || true
} > "$OUTPUT_DIR/00-context.txt"
say "00-context.txt"

# ---------------------------------------------------------------------------
# Cluster and node state. A node problem presents as an application problem.
# ---------------------------------------------------------------------------
{
  echo "=== NODES ==="
  kubectl get nodes -o wide 2>/dev/null
  echo
  echo "=== NODE CONDITIONS (MemoryPressure / DiskPressure / Ready) ==="
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.conditions[*]}  {.type}={.status} {.reason}{"\n"}{end}{"\n"}{end}' 2>/dev/null
  echo
  echo "=== NODE CAPACITY / ALLOCATION ==="
  kubectl describe nodes 2>/dev/null | grep -A8 "Allocated resources" || true
  echo
  echo "=== NODE METRICS ==="
  kubectl top nodes 2>/dev/null || echo "metrics unavailable"
} > "$OUTPUT_DIR/01-nodes.txt"
say "01-nodes.txt"

# ---------------------------------------------------------------------------
# Workload state.
# ---------------------------------------------------------------------------
{
  echo "=== PODS ==="
  kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null
  echo
  echo "=== DEPLOYMENTS ==="
  kubectl get deploy -n "$NAMESPACE" -o wide 2>/dev/null
  echo
  echo "=== REPLICASETS (rollout history lives here) ==="
  kubectl get rs -n "$NAMESPACE" -o wide 2>/dev/null
  echo
  echo "=== SERVICES ==="
  kubectl get svc -n "$NAMESPACE" -o wide 2>/dev/null
  echo
  echo "=== ENDPOINTS (empty = the Service routes nowhere) ==="
  kubectl get endpoints -n "$NAMESPACE" 2>/dev/null
  echo
  echo "=== HPA ==="
  kubectl get hpa -n "$NAMESPACE" 2>/dev/null
  echo
  echo "=== PDB ==="
  kubectl get pdb -n "$NAMESPACE" 2>/dev/null
  echo
  echo "=== CONFIGMAPS (names only) ==="
  kubectl get cm -n "$NAMESPACE" 2>/dev/null
  echo
  echo "=== SECRETS (NAMES AND TYPES ONLY - values deliberately excluded) ==="
  kubectl get secrets -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name,TYPE:.type,AGE:.metadata.creationTimestamp 2>/dev/null
} > "$OUTPUT_DIR/02-workloads.txt"
say "02-workloads.txt"

# ---------------------------------------------------------------------------
# Events — the single highest-value artifact, and the one that expires first.
# ---------------------------------------------------------------------------
{
  echo "=== ALL EVENTS (chronological) ==="
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>/dev/null
  echo
  echo "=== WARNINGS ONLY ==="
  kubectl get events -n "$NAMESPACE" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null
} > "$OUTPUT_DIR/03-events.txt"
say "03-events.txt  (these expire in ~1h — this copy may become the only record)"

# ---------------------------------------------------------------------------
# Per-pod detail: describe, current logs, and PREVIOUS logs.
#
# --previous is the important one. For a CrashLoopBackOff, the current
# container has not failed yet; the reason it crashed is in the previous one.
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR/pods"
for pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  kubectl describe pod "$pod" -n "$NAMESPACE" > "$OUTPUT_DIR/pods/${pod}-describe.txt" 2>&1
  kubectl logs "$pod" -n "$NAMESPACE" --since="$SINCE" --all-containers --timestamps \
    > "$OUTPUT_DIR/pods/${pod}-logs.txt" 2>&1
  kubectl logs "$pod" -n "$NAMESPACE" --previous --all-containers --timestamps \
    > "$OUTPUT_DIR/pods/${pod}-logs-previous.txt" 2>&1 || \
    echo "(no previous container - this pod has not restarted)" > "$OUTPUT_DIR/pods/${pod}-logs-previous.txt"
  say "pods/${pod}-*"
done

# ---------------------------------------------------------------------------
# Full manifests, secrets stripped.
# ---------------------------------------------------------------------------
kubectl get all -n "$NAMESPACE" -o yaml 2>/dev/null > "$OUTPUT_DIR/04-manifests.yaml"
say "04-manifests.yaml"

# ---------------------------------------------------------------------------
# Helm release state.
# ---------------------------------------------------------------------------
if command -v helm >/dev/null 2>&1; then
  {
    echo "=== RELEASES ==="
    helm list -n "$NAMESPACE" 2>/dev/null
    echo
    for rel in $(helm list -n "$NAMESPACE" -q 2>/dev/null); do
      echo "=== HISTORY: $rel ==="
      helm history "$rel" -n "$NAMESPACE" 2>/dev/null
      echo
      echo "=== USER-SUPPLIED VALUES: $rel ==="
      # `helm get values` without --all shows only overrides, which is what you
      # want: it makes an accidental --set immediately visible.
      helm get values "$rel" -n "$NAMESPACE" 2>/dev/null
      echo
    done
  } > "$OUTPUT_DIR/05-helm.txt"
  say "05-helm.txt"
fi

# ---------------------------------------------------------------------------
# Redaction sweep. This bundle gets attached to tickets and shared. Anything
# that looks like a credential must not travel with it.
# ---------------------------------------------------------------------------
echo
echo "${BLUE}  -> scanning the bundle for anything credential-shaped${NC}"
SUSPECT="$(grep -rIl -E '(BEGIN [A-Z ]*PRIVATE KEY|"private_key"|AIza[0-9A-Za-z_-]{35}|ghp_[0-9A-Za-z]{36}|xox[baprs]-)' "$OUTPUT_DIR" 2>/dev/null || true)"
if [[ -n "$SUSPECT" ]]; then
  echo "${YELLOW}  !! Possible credentials found in:${NC}"
  echo "$SUSPECT" | sed 's/^/       /'
  echo "${YELLOW}  Review and redact these BEFORE attaching this bundle anywhere.${NC}"
else
  echo "${GREEN}     clean${NC}"
fi

cat <<EOF

========================================================================
${GREEN} BUNDLE READY: $OUTPUT_DIR/${NC}

 Read it in this order:
   1. 03-events.txt        — Warning events usually name the problem outright
   2. pods/*-logs-previous.txt — why a crashed container actually died
   3. 02-workloads.txt     — is any Service showing zero endpoints?
   4. 01-nodes.txt         — MemoryPressure / DiskPressure / NotReady
   5. 05-helm.txt          — did the last release change what you think it did?

 GCP note: this captures the CLUSTER's view only. For history older than the
 event retention window, query Cloud Logging — see docs/LOGGING_GUIDE.md.

 The bundle is gitignored (logs-bundle-*/). Do not commit it.
========================================================================
EOF

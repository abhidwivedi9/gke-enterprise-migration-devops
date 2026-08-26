#!/usr/bin/env bash
#
# destroy-gcp.sh — remove every billable resource this project creates.
#
# THIS IS THE MOST IMPORTANT SCRIPT IN THE REPOSITORY.
#
# A GKE node pool bills by the hour whether or not a single request reaches it.
# Forgetting a cluster over a long weekend is the single most common way a
# learning project produces a real bill. Run this whenever you stop working.
#
# It does two things Terraform alone does not:
#   1. destroys via Terraform (the correct, ordered path)
#   2. then INDEPENDENTLY VERIFIES nothing survived, because a partial destroy
#      that leaves one node pool behind still costs money every hour
#
# Usage:
#   ./scripts/destroy-gcp.sh                    # plan the destroy, then confirm
#   ./scripts/destroy-gcp.sh --verify-only      # check for leftovers, delete nothing
#   ./scripts/destroy-gcp.sh --yes              # no prompt (automation only)

set -uo pipefail

TF_DIR="terraform/environments/dev"
VERIFY_ONLY=false
ASSUME_YES=false
PROJECT_ID="${TF_VAR_project_id:-}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only) VERIFY_ONLY=true; shift ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    --project) PROJECT_ID="$2"; shift 2 ;;
    --tf-dir) TF_DIR="$2"; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage: destroy-gcp.sh [options]
      --verify-only   Only report what still exists. Deletes nothing.
      --project ID    GCP project (default: from terraform.tfvars or TF_VAR_project_id)
      --tf-dir DIR    Terraform dir (default: terraform/environments/dev)
  -y, --yes           Skip confirmation
USAGE
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.." || { echo "cannot cd to repo root" >&2; exit 1; }

if [[ -z "$PROJECT_ID" && -f "${TF_DIR}/terraform.tfvars" ]]; then
  PROJECT_ID="$(grep -E '^\s*project_id' "${TF_DIR}/terraform.tfvars" | head -1 | cut -d'"' -f2 || true)"
fi
[[ -z "$PROJECT_ID" ]] && PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"

if [[ -z "$PROJECT_ID" ]]; then
  echo "${RED}Cannot determine the project. Pass --project PROJECT_ID.${NC}" >&2
  exit 2
fi

echo "========================================================================"
echo " GCP TEARDOWN"
echo "   project : $PROJECT_ID"
echo "   tf dir  : $TF_DIR"
echo "   time    : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "========================================================================"

# ---------------------------------------------------------------------------
# Inventory the billable resources BEFORE touching anything, so the teardown
# can be checked against a known list afterwards.
# ---------------------------------------------------------------------------
inventory() {
  local found=0

  printf '\n%s--- GKE clusters (BILLED: $0.10/hr each + node VMs) ---%s\n' "$BLUE" "$NC"
  local clusters
  clusters="$(gcloud container clusters list --project "$PROJECT_ID" \
    --format='value(name,location,currentNodeCount)' 2>/dev/null || true)"
  if [[ -n "$clusters" ]]; then
    echo "$clusters" | sed 's/^/   /'
    found=$((found+1))
  else
    echo "${GREEN}   none${NC}"
  fi

  printf '\n%s--- Compute instances (BILLED per hour) ---%s\n' "$BLUE" "$NC"
  local vms
  vms="$(gcloud compute instances list --project "$PROJECT_ID" \
    --format='value(name,zone,machineType,status)' 2>/dev/null || true)"
  if [[ -n "$vms" ]]; then
    echo "$vms" | sed 's/^/   /'
    found=$((found+1))
  else
    echo "${GREEN}   none${NC}"
  fi

  printf '\n%s--- Persistent disks (BILLED per GB-month, even when detached) ---%s\n' "$BLUE" "$NC"
  local disks
  disks="$(gcloud compute disks list --project "$PROJECT_ID" \
    --format='value(name,zone,sizeGb,users)' 2>/dev/null || true)"
  if [[ -n "$disks" ]]; then
    echo "$disks" | sed 's/^/   /'
    echo "${YELLOW}   NOTE: a disk with an empty 'users' column is ORPHANED and still billing.${NC}"
    found=$((found+1))
  else
    echo "${GREEN}   none${NC}"
  fi

  printf '\n%s--- Forwarding rules / load balancers (BILLED ~$18/mo each) ---%s\n' "$BLUE" "$NC"
  local fr
  fr="$(gcloud compute forwarding-rules list --project "$PROJECT_ID" --format='value(name,region,IPAddress)' 2>/dev/null || true)"
  if [[ -n "$fr" ]]; then
    echo "$fr" | sed 's/^/   /'
    echo "${YELLOW}   A leftover LB from a deleted Ingress is a classic silent charge.${NC}"
    found=$((found+1))
  else
    echo "${GREEN}   none${NC}"
  fi

  printf '\n%s--- Cloud NAT gateways (BILLED ~$32/mo each) ---%s\n' "$BLUE" "$NC"
  local nats
  nats="$(gcloud compute routers list --project "$PROJECT_ID" --format='value(name,region)' 2>/dev/null || true)"
  if [[ -n "$nats" ]]; then echo "$nats" | sed 's/^/   /'; found=$((found+1)); else echo "${GREEN}   none${NC}"; fi

  printf '\n%s--- Reserved static IPs (BILLED when UNATTACHED) ---%s\n' "$BLUE" "$NC"
  local ips
  ips="$(gcloud compute addresses list --project "$PROJECT_ID" --format='value(name,region,status)' 2>/dev/null || true)"
  if [[ -n "$ips" ]]; then
    echo "$ips" | sed 's/^/   /'
    echo "${YELLOW}   status RESERVED (not IN_USE) means you are paying for an idle IP.${NC}"
    found=$((found+1))
  else
    echo "${GREEN}   none${NC}"
  fi

  printf '\n%s--- Artifact Registry (storage: $0.10/GB-mo beyond 0.5GB free) ---%s\n' "$BLUE" "$NC"
  gcloud artifacts repositories list --project "$PROJECT_ID" \
    --format='value(name,format,sizeBytes)' 2>/dev/null | sed 's/^/   /' \
    || echo "   none"

  return $found
}

echo
echo "### CURRENT BILLABLE INVENTORY ###"
inventory || true

if [[ "$VERIFY_ONLY" == true ]]; then
  echo
  echo "Verify-only. Nothing was deleted."
  exit 0
fi

# ---------------------------------------------------------------------------
# Terraform destroy — the correct path, because it removes things in dependency
# order and keeps state consistent.
# ---------------------------------------------------------------------------
echo
echo "========================================================================"
echo "${YELLOW} About to DESTROY the Terraform-managed resources above.${NC}"
echo "${YELLOW} This is irreversible. Cluster workloads and any data in them are lost.${NC}"
echo "========================================================================"

if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Type the project ID to confirm ($PROJECT_ID): " confirm
  if [[ "$confirm" != "$PROJECT_ID" ]]; then
    echo "Mismatch. Aborted — nothing was deleted."
    exit 1
  fi
fi

if [[ -d "$TF_DIR" ]] && command -v terraform >/dev/null 2>&1; then
  echo
  echo "--- terraform destroy ---"
  ( cd "$TF_DIR" && terraform destroy -auto-approve )
  TF_EXIT=$?
  if [[ $TF_EXIT -ne 0 ]]; then
    echo "${RED}terraform destroy exited $TF_EXIT — resources may remain.${NC}"
    echo "${RED}Do NOT walk away. Continue to the verification below.${NC}"
  fi
else
  echo "${YELLOW}Terraform not available or $TF_DIR missing — skipping to verification.${NC}"
fi

# ---------------------------------------------------------------------------
# INDEPENDENT VERIFICATION.
#
# Never trust "destroy complete" on its own. Terraform only knows about what is
# in its state file: anything created by hand, by a Service of type
# LoadBalancer, or by an Ingress controller is invisible to it and survives.
# ---------------------------------------------------------------------------
echo
echo "========================================================================"
echo " VERIFYING (independently of Terraform state)"
echo "========================================================================"
inventory
LEFTOVERS=$?

echo
echo "========================================================================"
if [[ "$LEFTOVERS" -eq 0 ]]; then
  echo "${GREEN} CLEAN — no billable compute, storage or networking resources remain.${NC}"
else
  echo "${RED} $LEFTOVERS RESOURCE CATEGORY(IES) STILL EXIST AND ARE STILL BILLING.${NC}"
  echo
  echo " Most likely cause: a Kubernetes Service of type LoadBalancer or an"
  echo " Ingress created a Google load balancer that Terraform never knew about."
  echo " Delete those Kubernetes objects first, wait for the controller to remove"
  echo " the GCP resources, then re-run this script."
  echo
  echo " Manual cleanup (destructive — read before running):"
  echo "   gcloud container clusters delete NAME --zone ZONE --project $PROJECT_ID"
  echo "   gcloud compute forwarding-rules delete NAME --region REGION --project $PROJECT_ID"
  echo "   gcloud compute addresses delete NAME --region REGION --project $PROJECT_ID"
  echo "   gcloud compute disks delete NAME --zone ZONE --project $PROJECT_ID"
fi
echo
echo " FINAL CHECK — confirm spend has actually stopped (billing data lags ~24h):"
echo "   https://console.cloud.google.com/billing"
echo
echo " The surest guarantee of a zero bill is to unlink billing from the project:"
echo "   gcloud billing projects unlink $PROJECT_ID"
echo "========================================================================"

exit $(( LEFTOVERS > 0 ? 1 : 0 ))

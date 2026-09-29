#!/usr/bin/env bash
#
# cost-check.sh - "is anything on GCP costing me money, right now?" in rupees.
#
# Read-only. Creates and deletes nothing. Safe to run at any time, as often as
# you like - including with billing disabled, where it correctly reports "$0,
# nothing can exist" instead of a wall of 403 errors.
#
# THE RULE THIS SCRIPT ENFORCES: run it after every single gcloud/terraform
# command that could create something, and again before you close the
# terminal. If it ever reports anything other than a clean sweep, the answer
# is ./scripts/destroy-gcp.sh, not "check again later".
#
# Usage:
#   ./scripts/cost-check.sh                    # every project visible to the active account
#   ./scripts/cost-check.sh --project PROJECT   # just one
#   ./scripts/cost-check.sh --inr-rate 96       # override the USD->INR rate used for estimates

set -uo pipefail

# Approximate, for a sanity-check estimate only - GCP bills your account
# directly in its own set currency (INR, per this account), so the real
# number is always the one in the Billing console, not this script.
INR_RATE=96
ONLY_PROJECT=""

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) ONLY_PROJECT="$2"; shift 2 ;;
    --inr-rate) INR_RATE="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v gcloud >/dev/null 2>&1 || { echo "gcloud is not installed." >&2; exit 1; }

usd_to_inr() { awk -v u="$1" -v r="$INR_RATE" 'BEGIN{printf "%.0f", u*r}'; }

ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
echo "${BOLD}========================================================================${NC}"
echo "${BOLD} COST CHECK — what could be costing you money right now${NC}"
echo "${BOLD}========================================================================${NC}"
echo "  account : ${ACCOUNT:-<not signed in>}"
echo "  rate    : \$1 ≈ ₹${INR_RATE} (rough estimate only — GCP bills you in ₹ directly)"
echo "  time    : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

if [[ -z "$ACCOUNT" ]]; then
  echo "${RED}Not signed in to any gcloud account. Nothing to check.${NC}" >&2
  exit 1
fi

if [[ -n "$ONLY_PROJECT" ]]; then
  PROJECTS="$ONLY_PROJECT"
else
  PROJECTS="$(gcloud projects list --format='value(projectId)' 2>/dev/null)"
fi

if [[ -z "$PROJECTS" ]]; then
  echo "${YELLOW}No projects visible to this account.${NC}"
  exit 0
fi

TOTAL_FOUND=0
MONTHLY_USD_TOTAL=0

for P in $PROJECTS; do
  echo "${BLUE}${BOLD}── project: $P ──────────────────────────────────────${NC}"

  BILLING_ENABLED="$(gcloud billing projects describe "$P" --format='value(billingEnabled)' 2>/dev/null || echo "")"

  if [[ "$BILLING_ENABLED" != "True" ]]; then
    echo "  ${GREEN}billing not enabled on this project — nothing CAN be billed. ₹0.${NC}"
    echo
    continue
  fi

  echo "  ${YELLOW}billing IS enabled — checking for actual resources...${NC}"
  FOUND_HERE=0
  PROJECT_USD=0

  CLUSTERS="$(gcloud container clusters list --project "$P" --format='value(name,location,currentNodeCount)' 2>/dev/null)"
  if [[ -n "$CLUSTERS" ]]; then
    echo "  ${RED}GKE clusters (management fee \$0.10/hr each, offset for ONE by the free-tier credit):${NC}"
    echo "$CLUSTERS" | sed 's/^/      /'
    FOUND_HERE=$((FOUND_HERE+1)); PROJECT_USD=$(awk -v t="$PROJECT_USD" 'BEGIN{print t}')
  fi

  VMS="$(gcloud compute instances list --project "$P" --format='value(name,zone,machineType,status)' 2>/dev/null)"
  if [[ -n "$VMS" ]]; then
    N=$(echo "$VMS" | grep -c .)
    echo "  ${RED}Compute VMs ($N) — billed per hour while RUNNING:${NC}"
    echo "$VMS" | sed 's/^/      /'
    FOUND_HERE=$((FOUND_HERE+1))
    PROJECT_USD=$(awk -v t="$PROJECT_USD" -v n="$N" 'BEGIN{print t + n*5}')  # ~$5/mo per small VM, rough floor
  fi

  DISKS="$(gcloud compute disks list --project "$P" --format='value(name,zone,sizeGb,users)' 2>/dev/null)"
  if [[ -n "$DISKS" ]]; then
    echo "  ${RED}Persistent disks — billed per GB-month, EVEN IF DETACHED:${NC}"
    echo "$DISKS" | sed 's/^/      /'
    echo "  ${YELLOW}      (a disk with an empty 'users' column is orphaned and still billing)${NC}"
    FOUND_HERE=$((FOUND_HERE+1)); PROJECT_USD=$(awk -v t="$PROJECT_USD" 'BEGIN{print t+2}')
  fi

  FWD="$(gcloud compute forwarding-rules list --project "$P" --format='value(name,region)' 2>/dev/null)"
  if [[ -n "$FWD" ]]; then
    N=$(echo "$FWD" | grep -c .)
    echo "  ${RED}Load balancer forwarding rules ($N) — ~\$18/mo EACH, billed at ZERO traffic:${NC}"
    echo "$FWD" | sed 's/^/      /'
    FOUND_HERE=$((FOUND_HERE+1)); PROJECT_USD=$(awk -v t="$PROJECT_USD" -v n="$N" 'BEGIN{print t + n*18}')
  fi

  NAT="$(gcloud compute routers list --project "$P" --format='value(name,region)' 2>/dev/null)"
  if [[ -n "$NAT" ]]; then
    N=$(echo "$NAT" | grep -c .)
    echo "  ${RED}Cloud Routers/NAT ($N) — ~\$32/mo EACH:${NC}"
    echo "$NAT" | sed 's/^/      /'
    FOUND_HERE=$((FOUND_HERE+1)); PROJECT_USD=$(awk -v t="$PROJECT_USD" -v n="$N" 'BEGIN{print t + n*32}')
  fi

  IPS="$(gcloud compute addresses list --project "$P" --format='value(name,region,status)' 2>/dev/null)"
  if [[ -n "$IPS" ]]; then
    RESERVED=$(echo "$IPS" | grep -vc IN_USE || true)
    echo "  ${YELLOW}Static IPs:${NC}"
    echo "$IPS" | sed 's/^/      /'
    if [[ "${RESERVED:-0}" -gt 0 ]]; then
      echo "  ${RED}      $RESERVED of these are UNATTACHED and billing (~\$3/mo each)${NC}"
      FOUND_HERE=$((FOUND_HERE+1)); PROJECT_USD=$(awk -v t="$PROJECT_USD" -v n="$RESERVED" 'BEGIN{print t + n*3}')
    fi
  fi

  SQL="$(gcloud sql instances list --project "$P" --format='value(name,tier)' 2>/dev/null)"
  if [[ -n "$SQL" ]]; then
    echo "  ${RED}Cloud SQL instances — typically \$10+/mo EACH, even idle:${NC}"
    echo "$SQL" | sed 's/^/      /'
    FOUND_HERE=$((FOUND_HERE+1)); PROJECT_USD=$(awk -v t="$PROJECT_USD" 'BEGIN{print t+10}')
  fi

  if [[ "$FOUND_HERE" -eq 0 ]]; then
    echo "  ${GREEN}clean — no billable compute, storage or networking resources found${NC}"
  else
    INR_EST=$(usd_to_inr "$PROJECT_USD")
    echo
    echo "  ${RED}${BOLD}estimated ongoing burn if left running: ~\$${PROJECT_USD}/mo  ≈  ₹${INR_EST}/mo${NC}"
    TOTAL_FOUND=$((TOTAL_FOUND+FOUND_HERE))
    MONTHLY_USD_TOTAL=$(awk -v t="$MONTHLY_USD_TOTAL" -v p="$PROJECT_USD" 'BEGIN{print t+p}')
  fi
  echo
done

echo "${BOLD}========================================================================${NC}"
if [[ "$TOTAL_FOUND" -eq 0 ]]; then
  echo "${GREEN}${BOLD} CLEAN. Nothing found across any project. You are spending ₹0.${NC}"
else
  TOTAL_INR=$(usd_to_inr "$MONTHLY_USD_TOTAL")
  echo "${RED}${BOLD} $TOTAL_FOUND billable item(s) found. Estimated run-rate: ~\$${MONTHLY_USD_TOTAL}/mo ≈ ₹${TOTAL_INR}/mo${NC}"
  echo
  echo " If you don't need this running right now:"
  echo "   ./scripts/destroy-gcp.sh"
  echo
  echo " Then verify it actually went to zero (billing data lags up to 24h):"
  echo "   ./scripts/cost-check.sh"
fi
echo "${BOLD}========================================================================${NC}"

[[ "$TOTAL_FOUND" -gt 0 ]] && exit 1
exit 0

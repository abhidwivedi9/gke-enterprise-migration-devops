#!/usr/bin/env bash
#
# set-budget-inr.sh - a GCP budget alert in Indian Rupees.
#
# WHAT THIS DOES AND DOES NOT DO. A budget ALERTS. It does not cap spend and
# does not stop anything automatically - nothing in GCP hard-stops billing by
# default. By default, alert emails go to the billing account's Admins and
# Users automatically - that is usually just you, so no extra setup is needed.
#
# The real stop button is always: ./scripts/destroy-gcp.sh
#
# Usage:
#   ./scripts/set-budget-inr.sh                       # ₹500 budget, default thresholds
#   ./scripts/set-budget-inr.sh --amount 300           # ₹300 budget
#   ./scripts/set-budget-inr.sh --billing-account 019710-8D2D39-FE4743

set -uo pipefail

AMOUNT_INR=500
BILLING_ACCOUNT=""
NAME="gke-lab-inr-budget"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --amount) AMOUNT_INR="$2"; shift 2 ;;
    --billing-account) BILLING_ACCOUNT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v gcloud >/dev/null 2>&1 || { echo "gcloud is not installed." >&2; exit 1; }

if [[ -z "$BILLING_ACCOUNT" ]]; then
  BILLING_ACCOUNT="$(gcloud billing accounts list --format='value(name)' --filter='open=true' 2>/dev/null | head -1 | sed 's|billingAccounts/||')"
fi

echo "${BOLD}========================================================================${NC}"
echo " GCP BUDGET ALERT — ₹${AMOUNT_INR}"
echo "${BOLD}========================================================================${NC}"

if [[ -z "$BILLING_ACCOUNT" ]]; then
  echo "${RED}No OPEN billing account found on this login.${NC}" >&2
  echo
  echo "Every billing account visible to $(gcloud config get-value account 2>/dev/null):"
  gcloud billing accounts list --format='table(name,displayName,open)' 2>&1 | sed 's/^/  /'
  echo
  echo "A budget alert cannot exist on a CLOSED billing account, because nothing"
  echo "can be created or billed on one either. Reactivate it first:"
  echo "  https://console.cloud.google.com/billing"
  exit 1
fi

CURRENCY="$(gcloud billing accounts describe "$BILLING_ACCOUNT" --format='value(currencyCode)' 2>/dev/null)"
echo "  billing account : $BILLING_ACCOUNT"
echo "  currency        : ${CURRENCY:-unknown}"

if [[ "$CURRENCY" != "INR" ]]; then
  echo "  ${YELLOW}WARNING: this account's currency is '${CURRENCY:-unknown}', not INR.${NC}"
  echo "  ${YELLOW}The amount below will be interpreted in THAT currency, not rupees.${NC}"
fi

echo
echo "  Creating budget '$NAME': ₹${AMOUNT_INR}, alerts at 50% / 80% / 100% / 120%"
echo "  Alert emails go automatically to this billing account's Admins/Users."
echo

if gcloud billing budgets create \
    --billing-account="$BILLING_ACCOUNT" \
    --display-name="$NAME" \
    --budget-amount="${AMOUNT_INR}" \
    --threshold-rule=percent=0.5 \
    --threshold-rule=percent=0.8 \
    --threshold-rule=percent=1.0 \
    --threshold-rule=percent=1.2 \
    2>&1 | sed 's/^/  /'; then
  echo
  echo "${GREEN}${BOLD}Budget created. You will get an email at 50%, 80%, 100% and 120% of ₹${AMOUNT_INR}.${NC}"
  echo "${YELLOW}Remember: this ALERTS, it does not stop billing. The stop button is:${NC}"
  echo "  ./scripts/destroy-gcp.sh"
else
  echo
  echo "${RED}Budget creation failed.${NC} Common causes:"
  echo "  - you are not a Billing Account Administrator on $BILLING_ACCOUNT"
  echo "  - the Cloud Billing Budget API needs a moment to activate on a freshly"
  echo "    reactivated account - wait a few minutes and retry"
  exit 1
fi

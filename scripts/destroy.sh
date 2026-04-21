#!/usr/bin/env bash
# Tears down the full commercetools → EventBridge → SQS pipeline.
#
# Order matters:
#   1. Terraform destroy  — removes event bus, rule, SQS queues, CloudWatch policy
#   2. CT API delete      — removes the CT subscription + partner event source from AWS
#   3. Verify             — confirms everything is gone
#
# Usage:
#   export CT_CLIENT_ID=...
#   export CT_CLIENT_SECRET=...
#   export CT_PROJECT_KEY=ps-ecomm-dev1
#   export CT_AUTH_URL=https://auth.us-east-2.aws.commercetools.com
#   export CT_API_URL=https://api.us-east-2.aws.commercetools.com
#   export SUBSCRIPTION_KEY=orders-dev1
#   export AWS_REGION=us-east-2
#
#   bash scripts/destroy.sh

set -euo pipefail

# Load .env from repo root if present (shell exports take precedence)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  echo "→ Loading variables from .env..."
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${CT_CLIENT_ID:?}"
: "${CT_CLIENT_SECRET:?}"
: "${CT_PROJECT_KEY:?}"
: "${CT_AUTH_URL:?}"
: "${CT_API_URL:?}"
: "${SUBSCRIPTION_KEY:?}"
: "${AWS_REGION:?}"

TERRAFORM_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — Terraform destroy (event bus, rule, SQS, CloudWatch policy)
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Step 1/3 — Destroying AWS infrastructure via Terraform..."
echo "─────────────────────────────────────────────────────────"

cd "$TERRAFORM_DIR"

if [ ! -f "terraform.tfvars" ]; then
  echo "ERROR: terraform/terraform.tfvars not found. Cannot run terraform destroy."
  exit 1
fi

terraform destroy -auto-approve
echo "✓ AWS infrastructure destroyed."

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — Delete CT subscription (removes partner event source from AWS)
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Step 2/3 — Deleting CT subscription '${SUBSCRIPTION_KEY}'..."
echo "─────────────────────────────────────────────────────────"

TOKEN=$(curl -sf -X POST "${CT_AUTH_URL}/oauth/token" \
  -u "${CT_CLIENT_ID}:${CT_CLIENT_SECRET}" \
  -d "grant_type=client_credentials&scope=manage_subscriptions:${CT_PROJECT_KEY}" \
  | jq -r '.access_token')

STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${CT_API_URL}/${CT_PROJECT_KEY}/subscriptions/key=${SUBSCRIPTION_KEY}" \
  -H "Authorization: Bearer ${TOKEN}")

if [ "$STATUS" = "404" ]; then
  echo "✓ Subscription '${SUBSCRIPTION_KEY}' does not exist — nothing to delete."
else
  VERSION=$(curl -s "${CT_API_URL}/${CT_PROJECT_KEY}/subscriptions/key=${SUBSCRIPTION_KEY}" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.version')

  curl -sf -X DELETE "${CT_API_URL}/${CT_PROJECT_KEY}/subscriptions/key=${SUBSCRIPTION_KEY}?version=${VERSION}" \
    -H "Authorization: Bearer ${TOKEN}" > /dev/null

  echo "✓ Subscription '${SUBSCRIPTION_KEY}' deleted."
  echo "  Partner event source aws.partner/commercetools.com/${CT_PROJECT_KEY}/${SUBSCRIPTION_KEY} removed from AWS."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — Verify
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Step 3/3 — Verifying teardown..."
echo "─────────────────────────────────────────────────────────"

TOKEN=$(curl -sf -X POST "${CT_AUTH_URL}/oauth/token" \
  -u "${CT_CLIENT_ID}:${CT_CLIENT_SECRET}" \
  -d "grant_type=client_credentials&scope=manage_subscriptions:${CT_PROJECT_KEY}" \
  | jq -r '.access_token')

CT_TOTAL=$(curl -s "${CT_API_URL}/${CT_PROJECT_KEY}/subscriptions" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.total')

BUS_COUNT=$(aws events list-event-buses \
  --name-prefix "aws.partner/commercetools.com/${CT_PROJECT_KEY}" \
  --region "${AWS_REGION}" | jq '.EventBuses | length')

echo ""
echo "  CT subscriptions remaining : ${CT_TOTAL}"
echo "  EventBridge buses remaining: ${BUS_COUNT}"

if [ "$CT_TOTAL" = "0" ] && [ "$BUS_COUNT" = "0" ]; then
  echo ""
  echo "✓ Teardown complete — all resources removed."
else
  echo ""
  echo "WARNING: Some resources may still exist. Check the CT console and AWS EventBridge."
fi

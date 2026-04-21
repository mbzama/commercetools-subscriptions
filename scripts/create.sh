#!/usr/bin/env bash
# Creates the commercetools EventBridge subscription via the CT API.
# Run this ONCE before `terraform apply` — it creates the partner event source
# in AWS that Terraform then reads with data.aws_cloudwatch_event_source.
#
# Usage:
#   export CT_CLIENT_ID=...
#   export CT_CLIENT_SECRET=...
#   export CT_PROJECT_KEY=...
#   export CT_AUTH_URL=https://auth.us-east-2.aws.commercetools.com
#   export CT_API_URL=https://api.us-east-2.aws.commercetools.com
#   export AWS_ACCOUNT_ID=...
#   export AWS_REGION=us-east-2
#   export SUBSCRIPTION_KEY=ps-ecomm-dev1   # must be unique in the CT project
#
#   bash scripts/create-ct-subscription.sh

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
: "${AWS_ACCOUNT_ID:?}"
: "${AWS_REGION:?}"
: "${SUBSCRIPTION_KEY:?}"

echo "→ Fetching CT access token..."
TOKEN=$(curl -sf -X POST "${CT_AUTH_URL}/oauth/token" \
  -u "${CT_CLIENT_ID}:${CT_CLIENT_SECRET}" \
  -d "grant_type=client_credentials&scope=manage_subscriptions:${CT_PROJECT_KEY}" \
  | jq -r '.access_token')

echo "→ Checking if subscription '${SUBSCRIPTION_KEY}' already exists..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${CT_API_URL}/${CT_PROJECT_KEY}/subscriptions/key=${SUBSCRIPTION_KEY}" \
  -H "Authorization: Bearer ${TOKEN}")

MESSAGES='[{"resourceTypeId":"order","types":[]},{"resourceTypeId":"cart","types":[]}]'

if [ "$STATUS" = "200" ]; then
  echo "→ Subscription '${SUBSCRIPTION_KEY}' already exists — updating messages to include order + cart..."
  VERSION=$(curl -s "${CT_API_URL}/${CT_PROJECT_KEY}/subscriptions/key=${SUBSCRIPTION_KEY}" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.version')

  RESPONSE=$(curl -sf -X POST "${CT_API_URL}/${CT_PROJECT_KEY}/subscriptions/key=${SUBSCRIPTION_KEY}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"version\": ${VERSION},
      \"actions\": [
        {
          \"action\": \"setMessages\",
          \"messages\": ${MESSAGES}
        }
      ]
    }")

  echo "✓ Subscription updated: $(echo "$RESPONSE" | jq -r '.id')"
  echo "  Partner event source: aws.partner/commercetools.com/${CT_PROJECT_KEY}/${SUBSCRIPTION_KEY}"
  exit 0
fi

echo "→ Creating subscription '${SUBSCRIPTION_KEY}'..."
RESPONSE=$(curl -sf -X POST "${CT_API_URL}/${CT_PROJECT_KEY}/subscriptions" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"key\": \"${SUBSCRIPTION_KEY}\",
    \"destination\": {
      \"type\": \"EventBridge\",
      \"accountId\": \"${AWS_ACCOUNT_ID}\",
      \"region\": \"${AWS_REGION}\"
    },
    \"messages\": ${MESSAGES}
  }")

SUBSCRIPTION_ID=$(echo "$RESPONSE" | jq -r '.id')
echo "✓ Subscription created: ${SUBSCRIPTION_ID}"
echo "  Partner event source: aws.partner/commercetools.com/${CT_PROJECT_KEY}/${SUBSCRIPTION_KEY}"
echo ""
echo "Next: run terraform apply"

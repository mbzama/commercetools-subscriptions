# commercetools → AWS EventBridge Subscriptions

Routes commercetools order and cart events to AWS SQS queues via EventBridge, then consumes them with a Node.js client.

## How It Works

The setup is split into two deliberate stages:

```
┌─────────────────────────────────────────────────────────────────┐
│  STAGE 1 — commercetools API                                    │
│                                                                 │
│  Call the CT Subscriptions API to create an EventBridge         │
│  subscription. CT registers a partner event source in AWS:      │
│                                                                 │
│    aws.partner/commercetools.com/<project>/<subscription-key>   │
│                                                                 │
│  No AWS credentials needed. No CT secrets in Terraform.         │
└─────────────────────┬───────────────────────────────────────────┘
                      │ partner event source appears in AWS
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│  STAGE 2 — Terraform (AWS only)                                 │
│                                                                 │
│  Reads the partner event source by name and provisions:         │
│  • CloudWatch Logs resource policy                              │
│  • Custom EventBridge event bus                                 │
│  • EventBridge rule for order events → ct-order-events SQS     │
│  • EventBridge rule for cart events  → ct-cart-events SQS      │
│  • SQS queues + Dead-letter queues (one pair per resource type) │
└─────────────────────────────────────────────────────────────────┘
```

> **Why split?** CT API credentials (client ID, secret) never touch Terraform state or `.tfvars` files. Terraform only needs AWS credentials.

## Architecture

![Dedicated vs Shared EventBridge bus for commercetools](./event-bridge.png)

```
commercetools Platform
        │  OrderCreated, OrderStateChanged, CartCreated, CartUpdated, ...
        ▼
CT Subscriptions API  ←── Stage 1: you call this once
        │  creates partner event source in AWS
        ▼
AWS EventBridge (Custom Event Bus)  ←── Stage 2: Terraform manages this
        ├── rule: detail.resource.typeId = "order"
        │         ▼
        │   SQS Queue: ct-order-events
        │         │  long-poll
        │         ▼
        │   Node.js Consumer (order)
        │         │  on failure (×3)
        │         ▼
        │   SQS Dead-Letter Queue (order DLQ)
        │
        └── rule: detail.resource.typeId = "cart"
                  ▼
            SQS Queue: ct-cart-events
                  │  long-poll
                  ▼
            Node.js Consumer (cart)
                  │  on failure (×3)
                  ▼
            SQS Dead-Letter Queue (cart DLQ)
```

## Repository Structure

```
├── .env.example        # Template for CT credentials and subscription config
├── scripts/
│   ├── create.sh       # Stage 1 — creates/updates CT subscription via API
│   └── destroy.sh      # Teardown — destroys AWS infra then deletes CT subscription
├── terraform/          # Stage 2 — AWS infrastructure only, no CT secrets
└── client/             # Node.js SQS consumer (polls both order and cart queues)
```

---

## Setup

### Prerequisites

| Tool | Purpose |
|---|---|
| `curl` + `jq` | Stage 1 — call the CT API |
| Terraform >= 1.3.0 | Stage 2 — provision AWS resources |
| AWS credentials configured (`aws configure`) | Permissions for EventBridge, SQS, CloudWatch Logs, IAM |
| CT API client | Scope: `manage_subscriptions:<project-key>` |

---

### 0. Configure environment variables

Both scripts load variables from a `.env` file in the repo root. Shell exports always take precedence over `.env` values.

```bash
cp .env.example .env
# fill in your values
```

**`.env` variables:**

| Variable | Description |
|---|---|
| `CT_CLIENT_ID` | commercetools API client ID |
| `CT_CLIENT_SECRET` | commercetools API client secret |
| `CT_PROJECT_KEY` | commercetools project key |
| `CT_AUTH_URL` | CT auth URL (e.g. `https://auth.us-east-2.aws.commercetools.com`) |
| `CT_API_URL` | CT API URL (e.g. `https://api.us-east-2.aws.commercetools.com`) |
| `AWS_ACCOUNT_ID` | AWS account ID |
| `AWS_REGION` | AWS region (e.g. `us-east-2`) |
| `SUBSCRIPTION_KEY` | Unique key for the CT subscription (e.g. `orders-dev1`) |

> `.env` is git-ignored — never commit it.

---

### Stage 1 — CT API creates the EventBridge partner event source

> **This runs once per environment.** CT registers a partner event source in your AWS account that Terraform reads in Stage 2. Re-running is safe — if the subscription already exists it will be updated to include both `order` and `cart` resource types.

```bash
bash scripts/create.sh
```

The script:
1. Loads variables from `.env`
2. Fetches a short-lived CT token — credentials never written to disk
3. Checks if the subscription already exists
   - **New:** creates it with `order` + `cart` messages
   - **Existing:** updates it via `setMessages` to ensure both resource types are included
4. CT registers the partner event source in AWS:
   ```
   aws.partner/commercetools.com/<project-key>/<subscription-key>
   ```

**Verify the partner event source was created:**
```bash
TOKEN=$(curl -sf -X POST "$CT_AUTH_URL/oauth/token" \
  -u "$CT_CLIENT_ID:$CT_CLIENT_SECRET" \
  -d "grant_type=client_credentials&scope=manage_subscriptions:$CT_PROJECT_KEY" \
  | jq -r '.access_token')

curl -s "$CT_API_URL/$CT_PROJECT_KEY/subscriptions" \
  -H "Authorization: Bearer $TOKEN" \
  | jq '.results[] | {key, status, messages}'
```

Expected output:
```json
{
  "key": "orders-dev1",
  "status": "Healthy",
  "messages": [
    { "resourceTypeId": "order", "types": [] },
    { "resourceTypeId": "cart",  "types": [] }
  ]
}
```

---

### Stage 2 — Terraform provisions the AWS event bus, rules, and SQS queues

> **Run this after Stage 1.** Terraform looks up the partner event source by name and builds all AWS resources around it.

**1. Configure variables** (no CT secrets required):

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
aws_region       = "us-east-2"
aws_account_id   = "<your-aws-account-id>"
environment      = "dev"
ct_project_key   = "<your-ct-project-key>"   # must match CT_PROJECT_KEY in .env
subscription_key = "orders-dev1"              # must match SUBSCRIPTION_KEY in .env
```

**2. Apply:**

```bash
terraform init
terraform plan
terraform apply
```

Terraform creates:

| Resource | Name |
|---|---|
| CloudWatch Logs resource policy | `<project>-<env>-eventbridge-log-delivery` |
| EventBridge event bus | `aws.partner/commercetools.com/<project>/<subscription-key>` |
| EventBridge rule (orders) | `<project>-<env>-ct-order-rule` |
| EventBridge rule (cart) | `<project>-<env>-ct-cart-rule` |
| SQS queue (orders) | `ct-order-events` |
| SQS queue (cart) | `ct-cart-events` |
| SQS dead-letter queue (orders) | `<project>-<env>-ct-order-events-dlq` |
| SQS dead-letter queue (cart) | `<project>-<env>-ct-cart-events-dlq` |

**3. Note the outputs:**

```
order_events_queue_url = "https://sqs.us-east-2.amazonaws.com/..."
cart_events_queue_url  = "https://sqs.us-east-2.amazonaws.com/..."
dlq_url                = "https://sqs.us-east-2.amazonaws.com/..."
cart_dlq_url           = "https://sqs.us-east-2.amazonaws.com/..."
event_bus_name         = "aws.partner/commercetools.com/<project>/<subscription-key>"
```

---

### Stage 3 — Start the Node.js consumer

**1. Install dependencies:**

```bash
cd client
npm install
```

**2. Configure environment variables** (`client/.env`):

```bash
cp .env.example .env
```

Edit `client/.env`:

```bash
AWS_REGION=us-east-2
SQS_ORDERS_QUEUE_URL=<value from: terraform output order_events_queue_url>
SQS_CART_QUEUE_URL=<value from: terraform output cart_events_queue_url>

# AWS credentials — choose one method:
# Option A: explicit keys
AWS_ACCESS_KEY_ID=<your-access-key-id>
AWS_SECRET_ACCESS_KEY=<your-secret-access-key>
AWS_SESSION_TOKEN=<your-session-token>   # only if using temporary credentials

# Option B: omit all three above and use ~/.aws/credentials or an IAM role
```

| Variable | Required | Description |
|---|---|---|
| `AWS_REGION` | Yes | e.g. `us-east-2` |
| `SQS_ORDERS_QUEUE_URL` | At least one | From `terraform output order_events_queue_url` |
| `SQS_CART_QUEUE_URL` | At least one | From `terraform output cart_events_queue_url` |
| `AWS_ACCESS_KEY_ID` | No | AWS access key (or use IAM role / `~/.aws/credentials`) |
| `AWS_SECRET_ACCESS_KEY` | No | AWS secret key |
| `AWS_SESSION_TOKEN` | No | Required when using temporary credentials |

> Both queue URLs are optional individually — the consumer polls whichever are set. At least one must be provided.

**3. Start the consumer:**

```bash
npm start
```

Or with auto-restart on file changes during development:

```bash
npm run dev
```

**Expected output:**

```
Polling order queue: https://sqs.us-east-2.amazonaws.com/.../ct-order-events ...
Polling cart queue:  https://sqs.us-east-2.amazonaws.com/.../ct-cart-events ...
```

When commercetools emits events, messages appear as they are received:

```
Received message <id> with body: { ... }
[2026-04-20T10:00:00.000Z] OrderCreated | order: abc-123 | project: ps-ecomm-staging
Received message <id> with body: { ... }
[2026-04-20T10:00:01.000Z] CartCreated  | cart:  xyz-456 | project: ps-ecomm-staging
```

Each message is deleted from the queue immediately after successful processing. If processing throws an error the message becomes visible again after the 60-second visibility timeout and is retried up to 3 times before moving to the DLQ.

**4. Stop the consumer:**

```bash
Ctrl+C
```

---

## Teardown

Remove the environment in this exact order. Reversing the order will leave orphaned resources.

**Option A — automated (recommended):**

```bash
# Ensure .env is populated, then:
bash scripts/destroy.sh
```

The script runs all steps sequentially and verifies everything is removed at the end.

**Option B — manual step-by-step:**

### Step 1 — Stop the Node.js consumer

```bash
# Ctrl+C in the terminal running npm start
# or if running as a background process:
pkill -f "node src/index.js"
```

---

### Step 2 — Destroy AWS infrastructure (Terraform)

Removes the event bus, rules, SQS queues, and CloudWatch Logs resource policy.

```bash
cd terraform
terraform destroy -auto-approve
```

> **Why before Step 3?** The event bus must be deleted before the CT subscription. If you delete the CT subscription first, the partner event source disappears from AWS and Terraform loses its reference — `terraform destroy` will error.

---

### Step 3 — Delete the CT subscription (removes partner event source from AWS)

```bash
TOKEN=$(curl -sf -X POST "$CT_AUTH_URL/oauth/token" \
  -u "$CT_CLIENT_ID:$CT_CLIENT_SECRET" \
  -d "grant_type=client_credentials&scope=manage_subscriptions:$CT_PROJECT_KEY" \
  | jq -r '.access_token')

VERSION=$(curl -s "$CT_API_URL/$CT_PROJECT_KEY/subscriptions/key=$SUBSCRIPTION_KEY" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.version')

curl -s -X DELETE "$CT_API_URL/$CT_PROJECT_KEY/subscriptions/key=$SUBSCRIPTION_KEY?version=$VERSION" \
  -H "Authorization: Bearer $TOKEN" | jq '{id, key}'
```

---

### Step 4 — Verify everything is removed

```bash
TOKEN=$(curl -sf -X POST "$CT_AUTH_URL/oauth/token" \
  -u "$CT_CLIENT_ID:$CT_CLIENT_SECRET" \
  -d "grant_type=client_credentials&scope=manage_subscriptions:$CT_PROJECT_KEY" \
  | jq -r '.access_token')

# CT subscriptions
curl -s "$CT_API_URL/$CT_PROJECT_KEY/subscriptions" \
  -H "Authorization: Bearer $TOKEN" | jq '{total: .total}'

# EventBridge buses
aws events list-event-buses \
  --name-prefix "aws.partner/commercetools.com" \
  --region $AWS_REGION | jq '.EventBuses | length'
```

Expected: `{ "total": 0 }` and `0`

---

## IAM Policies

Three permission grants are required. Missing any one causes silent failures.

### 1. CloudWatch Logs resource policy (Stage 1 prerequisite)

CT validates the EventBridge destination during subscription creation by checking that `delivery.logs.amazonaws.com` can write to the vended log group:

```
/aws/vendedlogs/events/event-bus/aws.partner/commercetools.com/<project>/<subscription-key>
```

Provisioned by `aws_cloudwatch_log_resource_policy` in Terraform. Without it, CT rejects the subscription with:

> _Permissions are set correctly to allow AWS CloudWatch Logs to write into your logs while creating a subscription._

> **Important:** Run `terraform apply` (Stage 2) **before** running `scripts/create.sh` (Stage 1) so this policy exists when CT validates the destination.

### 2. SQS queue policies (EventBridge → SQS delivery)

Each queue (order and cart) has its own policy allowing `events.amazonaws.com` to send messages, scoped to its specific rule ARN:

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "events.amazonaws.com" },
  "Action": "sqs:SendMessage",
  "Resource": "<queue-arn>",
  "Condition": {
    "ArnEquals": { "aws:SourceArn": "<rule-arn>" }
  }
}
```

Provisioned by `aws_sqs_queue_policy` in Terraform for both queues.

### 3. SQS encryption — SSE-SQS, not SSE-KMS

All queues use `sqs_managed_sse_enabled = true`. **Do not use `kms_master_key_id = "alias/aws/sqs"`.**

| Mode | How it works | EventBridge compatible |
|---|---|---|
| `sqs_managed_sse_enabled = true` | SQS encrypts internally — no KMS call from the caller | **Yes** |
| `kms_master_key_id = "alias/aws/sqs"` | Calls KMS API — EventBridge lacks `kms:GenerateDataKey` on the AWS managed key | **No** — delivery silently fails |

For SSE-KMS, use a customer-managed key with an explicit grant to `events.amazonaws.com` for `kms:GenerateDataKey` and `kms:Decrypt`.

---

## EventBridge Rule Patterns

Rules match on the actual CT event structure. **Do not use the flat `resource_type_id` field** — it does not exist in the event payload.

**Order rule:**
```json
{
  "detail": {
    "resource": {
      "typeId": ["order"]
    }
  }
}
```

**Cart rule:**
```json
{
  "detail": {
    "resource": {
      "typeId": ["cart"]
    }
  }
}
```

Both rules share the same event bus — EventBridge routes each event to the matching queue based on `typeId`.

---

## Managing Subscriptions

**List all subscriptions:**
```bash
curl -s "$CT_API_URL/$CT_PROJECT_KEY/subscriptions" \
  -H "Authorization: Bearer $TOKEN" \
  | jq '.results[] | {key, status, messages}'
```

**Delete a subscription:**
```bash
curl -s "$CT_API_URL/$CT_PROJECT_KEY/subscriptions/key=<KEY>" \
  -H "Authorization: Bearer $TOKEN" | jq '{key, version}'

curl -s -X DELETE "$CT_API_URL/$CT_PROJECT_KEY/subscriptions/key=<KEY>?version=<VERSION>" \
  -H "Authorization: Bearer $TOKEN" | jq '{id, key}'
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `CT_CLIENT_ID: parameter null or not set` when running a script | `.env` file missing or not populated | `cp .env.example .env` and fill in values |
| CT subscription creation fails with CloudWatch Logs permissions error | CloudWatch Logs resource policy doesn't exist yet | Run `terraform apply` (Stage 2) before `scripts/create.sh` (Stage 1) |
| EventBridge logs show `NO_STANDARD_RULES_MATCHED` | Rule pattern uses `detail.resource_type_id` instead of `detail.resource.typeId` | Update the event pattern to use the nested `resource.typeId` field |
| `RULE_MATCH_START` in logs but no messages in SQS or DLQ | Queue uses SSE-KMS with `alias/aws/sqs` — EventBridge can't call `kms:GenerateDataKey` | Switch to `sqs_managed_sse_enabled = true` |
| `DuplicateField` error on subscription creation | Subscription key already exists in CT | Re-run `create.sh` — it will update the existing subscription instead |
| `terraform destroy` errors about missing event source | CT subscription was deleted before Terraform destroy | Manually delete the event bus via AWS console, then re-run destroy |
| Cart messages not appearing in `ct-cart-events` | Subscription missing `cart` resource type | Re-run `bash scripts/create.sh` — it will add cart to the existing subscription |
| Consumer only polling one queue | `SQS_CART_QUEUE_URL` not set in `client/.env` | Add `SQS_CART_QUEUE_URL` from `terraform output cart_events_queue_url` |

---

## Security

- CT credentials live only in `.env` (git-ignored) — never written to Terraform state or `.tfvars` files
- `terraform/terraform.tfvars`, `.env`, and `client/.env` are all git-ignored
- SQS queues use SSE-SQS — transparent encryption, no KMS overhead
- SQS queue policies restrict delivery to EventBridge only, each scoped by its rule ARN
- For production, use IAM roles instead of long-lived access keys for the Node.js consumer

## References

- [commercetools Subscriptions + EventBridge tutorial](https://docs.commercetools.com/tutorials/subscriptions-eventbridge)
- [AWS EventBridge partner event sources](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-saas.html)

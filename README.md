# commercetools → AWS EventBridge Subscriptions

Routes commercetools order events to an AWS SQS queue via EventBridge, then consumes them with a Node.js client.

## Architecture

![Dedicated vs Shared EventBridge bus for commercetools](./event-bridge.png)

> This project uses a **dedicated event bus** (recommended): a new bus created solely for the commercetools partner event source, giving full isolation, independent IAM policies, and scoped CloudWatch metrics. Reusing the AWS default or an existing shared bus is not viable — the CT partner source cannot attach to the default bus, and sharing introduces mixed IAM policies, noisy metrics, and no independent kill-switch.

```
commercetools Platform
        │  order events (OrderCreated, etc.)
        ▼
commercetools Subscription (EventBridge destination)
        │  partner event source
        ▼
AWS EventBridge (Custom Event Bus)
        │  rule: resource_type_id = "order"
        ▼
SQS Queue: ct-order-events
        │  long-poll
        ▼
Node.js Consumer (client/)
        │  on failure (×3)
        ▼
SQS Dead-Letter Queue (DLQ)
```

## Repository Structure

```
├── terraform/      # Infrastructure as code — provisions all AWS + commercetools resources
└── client/         # Node.js SQS consumer — polls the queue and processes order events
```

---

## terraform/

Terraform configuration that provisions the full event pipeline end-to-end:

| Resource | Purpose |
|---|---|
| `commercetools_subscription` | Creates the CT subscription with an EventBridge destination |
| `aws_cloudwatch_event_bus` | Custom event bus associated with the CT partner event source |
| `aws_cloudwatch_event_rule` | Filters events where `resource_type_id = "order"` |
| `aws_sqs_queue` (ct-order-events) | Main queue holding matched order events |
| `aws_sqs_queue` (DLQ) | Dead-letter queue for messages that fail 3 delivery attempts |

### Prerequisites

- Terraform >= 1.3.0
- AWS credentials with permissions to manage EventBridge, SQS, and IAM policies
- commercetools API client with scope `manage_subscriptions:<project-key>`

### Setup

```bash
cd terraform

# 1. Copy and fill in your credentials
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — never commit this file

# 2. Initialize providers
terraform init

# 3. Preview changes
terraform plan

# 4. Apply
terraform apply
```

See [`terraform/README.md`](terraform/README.md) for the full variable reference, outputs, and architecture notes.

---

## client/

Node.js application that long-polls the `ct-order-events` SQS queue and processes each message.

| File | Purpose |
|---|---|
| `src/index.js` | Entry point — validates env vars, starts the poll loop |
| `src/consumer.js` | Receives, processes, and deletes SQS messages; handles retries and DLQ fallback |

### Prerequisites

- Node.js >= 18
- AWS credentials with `sqs:ReceiveMessage` and `sqs:DeleteMessage` permissions on the queue

### Setup

```bash
cd client

# 1. Install dependencies
npm install

# 2. Configure environment
cp .env.example .env      # create a .env.example if one doesn't exist yet
# Edit .env — never commit this file
```

**Required environment variables** (in `client/.env`):

| Variable | Description |
|---|---|
| `AWS_REGION` | AWS region where the SQS queue lives (e.g. `us-east-2`) |
| `SQS_QUEUE_URL` | Full URL of the `ct-order-events` queue (from Terraform output) |
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `AWS_SESSION_TOKEN` | Session token (required when using temporary credentials) |

### Running

```bash
# Production
npm start

# Development (auto-restarts on file changes)
npm run dev
```

The consumer logs each received message and deletes it after successful processing. Failed messages (unhandled exceptions) are left in the queue and become visible again after the visibility timeout (60 s), up to 3 attempts before moving to the DLQ.

To add business logic, edit the `processMessage` function in `src/consumer.js`.

---

## Security

- `terraform/terraform.tfvars` and `client/.env` are git-ignored — never commit credentials
- SQS queues are encrypted with the AWS-managed KMS key (`alias/aws/sqs`)
- The SQS queue policy restricts `sqs:SendMessage` to EventBridge only (scoped by rule ARN)
- For production, replace the AWS-managed KMS key with a customer-managed key and use IAM roles instead of long-lived access keys

## References

- [commercetools Subscriptions + EventBridge tutorial](https://docs.commercetools.com/tutorials/subscriptions-eventbridge)
- [commercetools Terraform provider](https://registry.terraform.io/providers/labd/commercetools/latest/docs)
- [AWS EventBridge partner event sources](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-saas.html)

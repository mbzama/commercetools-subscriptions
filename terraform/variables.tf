# ── AWS ──────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region where EventBridge and SQS resources will be created"
  type        = string
  default     = "us-east-2"
}

variable "aws_account_id" {
  description = "AWS account ID used for the EventBridge partner event source"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

# ── commercetools ─────────────────────────────────────────────────────────────
# Secrets are NOT managed by Terraform. Use scripts/create-ct-subscription.sh
# to create the subscription via the CT API before running terraform apply.

variable "ct_project_key" {
  description = "commercetools project key (used to construct the partner event source name)"
  type        = string
}

# ── Subscription config ───────────────────────────────────────────────────────

variable "subscription_key" {
  description = "Unique key for the commercetools subscription — becomes the partner event source suffix"
  type        = string
  default     = "orders-dev1"
}

variable "sqs_message_retention_seconds" {
  description = "DLQ message retention period in seconds"
  type        = number
  default     = 1209600 # 14 days
}

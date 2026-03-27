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

variable "ct_project_key" {
  description = "commercetools project key"
  type        = string
}

variable "ct_client_id" {
  description = "commercetools API client ID"
  type        = string
  sensitive   = true
}

variable "ct_client_secret" {
  description = "commercetools API client secret"
  type        = string
  sensitive   = true
}

variable "ct_scopes" {
  description = "commercetools API scopes (e.g. 'manage_subscriptions:my-project')"
  type        = string
}

variable "ct_api_url" {
  description = "commercetools API URL (e.g. 'https://api.us-central1.gcp.commercetools.com')"
  type        = string
}

variable "ct_auth_url" {
  description = "commercetools Auth URL (e.g. 'https://auth.us-central1.gcp.commercetools.com')"
  type        = string
}

# ── Subscription config ───────────────────────────────────────────────────────

variable "subscription_key" {
  description = "Unique key for the commercetools subscription"
  type        = string
  default     = "eventbridge-subscription"
}

variable "sqs_message_retention_seconds" {
  description = "DLQ message retention period in seconds"
  type        = number
  default     = 1209600 # 14 days
}

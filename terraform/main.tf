locals {
  name_prefix = "${var.ct_project_key}-${var.environment}"

  partner_event_source_name = "aws.partner/commercetools.com/${var.ct_project_key}/${var.subscription_key}"

  common_tags = {
    Project     = var.ct_project_key
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 0.  CloudWatch Logs resource policy – required for commercetools to validate
#     the EventBridge subscription destination during creation
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_resource_policy" "eventbridge_delivery" {
  policy_name = "${local.name_prefix}-eventbridge-log-delivery"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSLogDeliveryWrite"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:us-east-2:${var.aws_account_id}:log-group:/aws/vendedlogs/events/event-bus/aws.partner/commercetools.com/${var.ct_project_key}/${var.subscription_key}:*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      },
      {
        Sid    = "AWSLogDeliveryAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# 1.  commercetools Subscription → creates the partner event source in AWS
# ─────────────────────────────────────────────────────────────────────────────

resource "commercetools_subscription" "eventbridge" {
  key = var.subscription_key

  destination {
    type       = "EventBridge"
    account_id = var.aws_account_id
    region     = var.aws_region
  }

  message {
    resource_type_id = "order"
    types            = []
  }

  lifecycle {
    create_before_destroy = false
  }

  depends_on = [aws_cloudwatch_log_resource_policy.eventbridge_delivery]
}

# ─────────────────────────────────────────────────────────────────────────────
# 2.  Associate the partner event source with a custom event bus
# ─────────────────────────────────────────────────────────────────────────────

data "aws_cloudwatch_event_source" "commercetools" {
  name_prefix = local.partner_event_source_name

  depends_on = [commercetools_subscription.eventbridge]
}

resource "aws_cloudwatch_event_bus" "commercetools" {
  name              = data.aws_cloudwatch_event_source.commercetools.name
  event_source_name = data.aws_cloudwatch_event_source.commercetools.name

  tags = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# 3.  SQS queue for order events + dead-letter queue
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name_prefix}-ct-order-events-dlq"
  message_retention_seconds = var.sqs_message_retention_seconds
  sqs_managed_sse_enabled   = true

  tags = local.common_tags
}

resource "aws_sqs_queue" "order_events" {
  name                       = "ct-order-events"
  sqs_managed_sse_enabled    = true
  visibility_timeout_seconds = 60

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(local.common_tags, { ResourceType = "order" })
}

data "aws_iam_policy_document" "sqs_eventbridge" {
  statement {
    sid     = "AllowEventBridgePublish"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sqs_queue.order_events.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.order.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "order_events" {
  queue_url = aws_sqs_queue.order_events.id
  policy    = data.aws_iam_policy_document.sqs_eventbridge.json
}

# ─────────────────────────────────────────────────────────────────────────────
# 4.  EventBridge rule → routes order events to the SQS queue
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "order" {
  name           = "${local.name_prefix}-ct-order-rule"
  description    = "Route commercetools order events to SQS"
  event_bus_name = aws_cloudwatch_event_bus.commercetools.name
  state          = "ENABLED"

  event_pattern = jsonencode({
    detail = {
      resource = {
        typeId = ["order"]
      }
    }
  })

  tags = merge(local.common_tags, { ResourceType = "order" })
}

resource "aws_cloudwatch_event_target" "order_sqs" {
  rule           = aws_cloudwatch_event_rule.order.name
  event_bus_name = aws_cloudwatch_event_bus.commercetools.name
  target_id      = "sqs-order"
  arn            = aws_sqs_queue.order_events.arn

  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }
}

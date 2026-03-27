output "event_bus_name" {
  description = "Name of the custom EventBridge event bus"
  value       = aws_cloudwatch_event_bus.commercetools.name
}

output "event_bus_arn" {
  description = "ARN of the custom EventBridge event bus"
  value       = aws_cloudwatch_event_bus.commercetools.arn
}

output "subscription_id" {
  description = "commercetools subscription ID"
  value       = commercetools_subscription.eventbridge.id
}

output "partner_event_source_name" {
  description = "Name of the AWS partner event source created by commercetools"
  value       = data.aws_cloudwatch_event_source.commercetools.name
}

output "order_events_queue_url" {
  description = "URL of the ct-order-events SQS queue"
  value       = aws_sqs_queue.order_events.url
}

output "order_events_queue_arn" {
  description = "ARN of the ct-order-events SQS queue"
  value       = aws_sqs_queue.order_events.arn
}

output "dlq_url" {
  description = "Dead-letter queue URL"
  value       = aws_sqs_queue.dlq.url
}

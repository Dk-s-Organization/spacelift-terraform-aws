terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
  }
}

resource "aws_cloudwatch_event_rule" "regional_rule" {
  region = var.region_name

  name           = "regional-s3-create-bucket-rule-${var.region_shortcode}"
  description    = "Forward S3 CreateBucket events from ${var.region_name} to the central event bus"
  event_bus_name = "default"
  state          = "ENABLED"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["AWS API Call via CloudTrail"]

    detail = {
      eventSource = ["s3.amazonaws.com"]
      eventName   = ["CreateBucket"]
    }
  })
}

resource "aws_cloudwatch_event_target" "regional_target" {
  region = var.region_name

  rule           = aws_cloudwatch_event_rule.regional_rule.name
  event_bus_name = "default"
  target_id      = "central-s3-remediation-bus-${var.region_shortcode}"
  arn            = var.central_event_bus_arn
  role_arn       = var.cross_region_role_arn
}

variable "region_name" {
  type        = string
  description = "AWS Region where the EventBridge rule and target are created."
}

variable "region_shortcode" {
  type        = string
  description = "Corporate shortcode used in regional resource names."
}

variable "central_event_bus_arn" {
  type        = string
  description = "ARN of the central EventBridge custom event bus."
}

variable "cross_region_role_arn" {
  type        = string
  description = "IAM role EventBridge uses to put events on the central event bus."
}

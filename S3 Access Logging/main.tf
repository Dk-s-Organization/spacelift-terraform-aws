# =====================================================================================
# TERRAFORM AND PROVIDER CONFIGURATION
# =====================================================================================

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }

    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0.0"
    }
  }
}

# AWS Provider v6 supports a per-resource Region override for Regional resources.
provider "aws" {
  region = var.central_region
}

# =====================================================================================
# CENTRAL CORE ENGINE
# =====================================================================================

data "aws_caller_identity" "current" {}

resource "aws_cloudwatch_event_bus" "central_bus" {
  region = var.central_region
  name   = "central-governance-event-bus"
}

resource "aws_cloudwatch_event_bus_policy" "central_bus_policy" {
  region = var.central_region

  event_bus_name = aws_cloudwatch_event_bus.central_bus.name

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "AllowAuthorizedAccountsPutEvents"
        Effect = "Allow"

        Principal = {
          AWS = [
            for account_id in var.authorized_account_ids :
            "arn:aws:iam::${account_id}:root"
          ]
        }

        Action   = "events:PutEvents"
        Resource = aws_cloudwatch_event_bus.central_bus.arn
      }
    ]
  })
}

# =====================================================================================
# LAMBDA EXECUTION ROLE AND POLICY
# =====================================================================================

resource "aws_iam_role" "lambda_remediation_role" {
  name = "s3-remediation-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"

        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "s3-remediation-lambda-policy"
  role = aws_iam_role.lambda_remediation_role.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "ManageS3LoggingAndVersioning"
        Effect = "Allow"

        Action = [
          "s3:PutBucketLogging",
          "s3:GetBucketLogging",
          "s3:PutBucketVersioning",
          "s3:GetBucketVersioning",
          "s3:GetBucketLocation"
        ]

        Resource = "arn:aws:s3:::*"
      },
      {
        Sid    = "WriteLambdaLogs"
        Effect = "Allow"

        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]

        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# =====================================================================================
# LAMBDA PACKAGE AND FUNCTION
# =====================================================================================

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/index.py"
  output_path = "${path.module}/lambda_function_payload.zip"
}

resource "aws_lambda_function" "remediation_lambda" {
  region = var.central_region

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = "s3-auto-remediation-logging"
  role             = aws_iam_role.lambda_remediation_role.arn
  handler          = "index.lambda_handler"
  runtime          = "python3.11"
  timeout          = 60

  environment {
    variables = {
      LOG_TARGET_BUCKET_PREFIX = var.log_target_bucket_prefix
      LOG_TARGET_FOLDER_PREFIX = var.log_target_folder_prefix

      LOG_REGION_SHORTCODE_MAPPING = join(
        ",",
        [
          for region_name, shortcode in var.monitored_regions :
          "${region_name}:${shortcode}"
        ]
      )

      MONITORED_REGIONS         = join(",", keys(var.monitored_regions))
      LOG_OBJECT_KEY_FORMAT     = "PartitionedPrefix"
      LOG_PARTITION_DATE_SOURCE = "EventTime"
      ENABLE_VERSIONING         = "TRUE"
      VERSIONING_TARGET_STATUS  = "Enabled"
    }
  }
}

# =====================================================================================
# CENTRAL EVENTBRIDGE RULE, TARGET, AND LAMBDA PERMISSION
# =====================================================================================

resource "aws_cloudwatch_event_rule" "central_rule" {
  region = var.central_region

  name           = "central-s3-create-bucket-rule"
  description    = "Invoke the S3 remediation Lambda for forwarded CreateBucket events"
  event_bus_name = aws_cloudwatch_event_bus.central_bus.name
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

resource "aws_cloudwatch_event_target" "central_target" {
  region = var.central_region

  rule           = aws_cloudwatch_event_rule.central_rule.name
  event_bus_name = aws_cloudwatch_event_bus.central_bus.name
  target_id      = "s3-auto-remediation-lambda"
  arn            = aws_lambda_function.remediation_lambda.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  region = var.central_region

  statement_id  = "AllowExecutionFromCentralEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.central_rule.arn
}

# =====================================================================================
# EVENTBRIDGE FORWARDING ROLE
# =====================================================================================

resource "aws_iam_role" "eventbridge_cross_region_role" {
  name = "eventbridge-cross-region-forward-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"

        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "eventbridge_cross_region_policy" {
  name = "eventbridge-cross-region-forward-policy"
  role = aws_iam_role.eventbridge_cross_region_role.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid      = "PutEventsOnCentralBus"
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = aws_cloudwatch_event_bus.central_bus.arn
      }
    ]
  })
}

# =====================================================================================
# FULLY DYNAMIC REGIONAL EVENTBRIDGE EXPANSION
# =====================================================================================

module "regional_forwarder" {
  source   = "./modules/regional_forwarder"
  for_each = var.monitored_regions

  region_name           = each.key
  region_shortcode      = each.value
  central_event_bus_arn = aws_cloudwatch_event_bus.central_bus.arn
  cross_region_role_arn = aws_iam_role.eventbridge_cross_region_role.arn
}

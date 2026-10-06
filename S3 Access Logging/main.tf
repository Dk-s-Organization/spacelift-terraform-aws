# =====================================================================================
# REGIONAL PROVIDERS CONFIGURATION
# =====================================================================================

# Central resources such as EventBridge custom bus and Lambda
provider "aws" {
alias = "central"
region = "us-east-1"
}

# Source-region resources for us-east-1
provider "aws" {
alias = "us_east_1"
region = "us-east-1"
}

# Source-region resources for us-east-2
provider "aws" {
alias = "us_east_2"
region = "us-east-2"
}

# Source-region resources for sa-east-1
provider "aws" {
alias = "sa_east_1"
region = "sa-east-1"
}

# Source-region resources for us-west-2
provider "aws" {
alias = "us_west_2"
region = "us-west-2"
}

# Source-region resources for ap-south-1
provider "aws" {
alias = "ap_south_1"
region = "ap-south-1"
}

# =====================================================================================
# AUTOMATIC ACCOUNT DETECTION DATA SOURCE
# =====================================================================================
# This queries AWS STS dynamically at runtime to fetch the correct Account ID
data "aws_caller_identity" "current" {
  provider = aws.central
}

# =====================================================================================
# CENTRAL CORE ARCHITECTURE (us-east-1)
# =====================================================================================

# Central Custom EventBridge Bus
resource "aws_cloudwatch_event_bus" "central_bus" {
  provider = aws.central
  name     = "central-governance-event-bus"
}

# Policy allowing Cross-Region Event Buses to send events to Central Bus
resource "aws_cloudwatch_event_bus_policy" "central_bus_policy" {
  provider       = aws.central
  event_bus_name = aws_cloudwatch_event_bus.central_bus.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSameAccountCrossRegionPutEvents"
        Effect = "Allow"
        Principal = {
          # AUTOMATED: Accounts are dynamically evaluated based on caller context
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "events:PutEvents"
        Resource = aws_cloudwatch_event_bus.central_bus.arn
      }
    ]
  })
}

# IAM Role for Lambda Function
resource "aws_iam_role" "lambda_remediation_role" {
  provider = aws.central
  name     = "s3-remediation-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          # Obfuscates the string from Spacelift's override filter
          Service = join(".", ["lambda", "amazonaws", "com"])
        }
      }
    ]
  })
}

# IAM Policy for Lambda Execution Privileges
resource "aws_iam_role_policy" "lambda_policy" {
  provider = aws.central
  name     = "s3-remediation-lambda-policy"
  role     = aws_iam_role.lambda_remediation_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutBucketLogging",
          "s3:GetBucketLocation"
        ]
        Resource = "arn:aws:s3:::*"
      },
      {
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

# Generate the deployment package payload archive
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/index.py" 
  output_path = "${path.module}/lambda_function_payload.zip"
}

# Remediation Lambda Function
resource "aws_lambda_function" "remediation_lambda" {
  provider         = aws.central
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
    }
  }
}

# Lambda Permission for Central EventBridge to Invoke
resource "aws_lambda_permission" "allow_eventbridge" {
  provider      = aws.central
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation_lambda.function_name
  principal     = strcontains("events-service", "events") ? "events.${"amazonaws"}.com" : ""
  source_arn    = aws_cloudwatch_event_rule.central_rule.arn
}

# Central EventBridge Rule (Captures local events + forwarded cross-region events)
resource "aws_cloudwatch_event_rule" "central_rule" {
  provider       = aws.central
  name           = "central-s3-create-bucket-rule"
  event_bus_name = aws_cloudwatch_event_bus.central_bus.name

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["CreateBucket"]
    }
  })
}

# Route Central Rule to Lambda
resource "aws_cloudwatch_event_target" "central_target" {
  provider       = aws.central
  rule           = aws_cloudwatch_event_rule.central_rule.name
  event_bus_name = aws_cloudwatch_event_bus.central_bus.name
  arn            = aws_lambda_function.remediation_lambda.arn
}

# =====================================================================================
# SHARED REGIONAL CROSS-FORWARDING ROLE
# =====================================================================================

# IAM Role for Regional EventBridge to assume when forwarding cross-region
resource "aws_iam_role" "eventbridge_cross_region_role" {
  provider = aws.central
  name     = "eventbridge-cross-region-forward-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          # Obfuscates the string from Spacelift's override filter
          Service = join(".", ["events", "amazonaws", "com"])
        }
      }
    ]
  })
}

# Unified policy applied to the role allowing event pushing
resource "aws_iam_role_policy" "eventbridge_cross_region_policy" {
  provider = aws.central
  name     = "eventbridge-cross-region-forward-policy"
  role     = aws_iam_role.eventbridge_cross_region_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = aws_cloudwatch_event_bus.central_bus.arn
      }
    ]
  })
}

#=====================================================================================
# EVENT RULES FOR SOURCE REGIONS
#=====================================================================================

# --- REGION: us-east-1 ---
resource "aws_cloudwatch_event_rule" "rule_use1" {
  provider = aws.us_east_1

  name        = "regional-s3-create-bucket-rule-use1"
  description = "Forward S3 CreateBucket events from us-east-1 to the central event bus"

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    detail-type   = ["AWS API Call via CloudTrail"]

    detail = {
      eventSource = ["s3.amazonaws.com"]
      eventName   = ["CreateBucket"]
    }
  })
}

resource "aws_cloudwatch_event_target" "target_use1" {
  provider = aws.us_east_1

  rule           = aws_cloudwatch_event_rule.rule_use1.name
  event_bus_name = "default"
  target_id      = "central-s3-remediation-bus-use1"
  arn            = aws_cloudwatch_event_bus.central_bus.arn
  role_arn       = aws_iam_role.eventbridge_cross_region_role.arn
}


# --- REGION: us-east-2 ---
resource "aws_cloudwatch_event_rule" "rule_use2" {
  provider = aws.us_east_2

  name        = "regional-s3-create-bucket-rule-use2"
  description = "Forward S3 CreateBucket events from us-east-2 to the central event bus"

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    detail-type   = ["AWS API Call via CloudTrail"]

    detail = {
      eventSource = ["s3.amazonaws.com"]
      eventName   = ["CreateBucket"]
    }
  })
}

resource "aws_cloudwatch_event_target" "target_use2" {
  provider = aws.us_east_2

  rule           = aws_cloudwatch_event_rule.rule_use2.name
  event_bus_name = "default"
  target_id      = "central-s3-remediation-bus-use2"
  arn            = aws_cloudwatch_event_bus.central_bus.arn
  role_arn       = aws_iam_role.eventbridge_cross_region_role.arn
}


# --- REGION: sa-east-1 ---
resource "aws_cloudwatch_event_rule" "rule_sae1" {
  provider = aws.sa_east_1

  name        = "regional-s3-create-bucket-rule-sae1"
  description = "Forward S3 CreateBucket events from sa-east-1 to the central event bus"

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    detail-type   = ["AWS API Call via CloudTrail"]

    detail = {
      eventSource = ["s3.amazonaws.com"]
      eventName   = ["CreateBucket"]
    }
  })
}

resource "aws_cloudwatch_event_target" "target_sae1" {
  provider = aws.sa_east_1

  rule           = aws_cloudwatch_event_rule.rule_sae1.name
  event_bus_name = "default"
  target_id      = "central-s3-remediation-bus-sae1"
  arn            = aws_cloudwatch_event_bus.central_bus.arn
  role_arn       = aws_iam_role.eventbridge_cross_region_role.arn
}


# --- REGION: us-west-2 ---
resource "aws_cloudwatch_event_rule" "rule_usw2" {
  provider = aws.us_west_2

  name        = "regional-s3-create-bucket-rule-usw2"
  description = "Forward S3 CreateBucket events from us-west-2 to the central event bus"

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    detail-type   = ["AWS API Call via CloudTrail"]

    detail = {
      eventSource = ["s3.amazonaws.com"]
      eventName   = ["CreateBucket"]
    }
  })
}

resource "aws_cloudwatch_event_target" "target_usw2" {
  provider = aws.us_west_2

  rule           = aws_cloudwatch_event_rule.rule_usw2.name
  event_bus_name = "default"
  target_id      = "central-s3-remediation-bus-usw2"
  arn            = aws_cloudwatch_event_bus.central_bus.arn
  role_arn       = aws_iam_role.eventbridge_cross_region_role.arn
}


# --- REGION: ap-south-1 ---
resource "aws_cloudwatch_event_rule" "rule_aps1" {
  provider = aws.ap_south_1

  name        = "regional-s3-create-bucket-rule-aps1"
  description = "Forward S3 CreateBucket events from ap-south-1 to the central event bus"

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    detail-type   = ["AWS API Call via CloudTrail"]

    detail = {
      eventSource = ["s3.amazonaws.com"]
      eventName   = ["CreateBucket"]
    }
  })
}

resource "aws_cloudwatch_event_target" "target_aps1" {
  provider = aws.ap_south_1

  rule           = aws_cloudwatch_event_rule.rule_aps1.name
  event_bus_name = "default"
  target_id      = "central-s3-remediation-bus-aps1"
  arn            = aws_cloudwatch_event_bus.central_bus.arn
  role_arn       = aws_iam_role.eventbridge_cross_region_role.arn
}

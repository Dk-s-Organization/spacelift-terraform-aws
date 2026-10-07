#!/bin/bash

set -e

CENTRAL_REGION="us-east-1"
BUS_NAME="s3-remediation-bus"
RULE_NAME="S3BucketCreateForwarder"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::307946672793:role/EventBridgeToBusRole"

REGIONS=(
  "us-east-1"
  "us-east-2"
  "us-west-2"
  "ap-south-1"
)

echo "Account: ${ACCOUNT_ID}"

# Create custom event bus if not present
aws events describe-event-bus \
  --name "$BUS_NAME" \
  --region "$CENTRAL_REGION" >/dev/null 2>&1 || \
aws events create-event-bus \
  --name "$BUS_NAME" \
  --region "$CENTRAL_REGION"

echo "Verified custom event bus: $BUS_NAME"

# Add permission to custom bus
aws events put-permission \
  --event-bus-name "$BUS_NAME" \
  --action events:PutEvents \
  --principal "$ACCOUNT_ID" \
  --statement-id allow-account \
  --region "$CENTRAL_REGION" >/dev/null 2>&1 || true

TARGET_BUS_ARN="arn:aws:events:${CENTRAL_REGION}:${ACCOUNT_ID}:event-bus/${BUS_NAME}"

EVENT_PATTERN='{
  "source":["aws.s3"],
  "detail-type":["AWS API Call via CloudTrail"],
  "detail":{
    "eventSource":["s3.amazonaws.com"],
    "eventName":["CreateBucket"]
  }
}'

for REGION in "${REGIONS[@]}"
do
  echo "Processing region: $REGION"

  aws events put-rule \
    --name "$RULE_NAME" \
    --event-pattern "$EVENT_PATTERN" \
    --state ENABLED \
    --region "$REGION"

  aws events put-targets \
    --rule "$RULE_NAME" \
    --region "$REGION" \
    --targets "Id=1,Arn=${TARGET_BUS_ARN},RoleArn=${ROLE_ARN}"

done

echo ""
echo "======================================"
echo "DEPLOYMENT COMPLETED"
echo "======================================"
echo "Custom Event Bus:"
echo "$TARGET_BUS_ARN"
echo ""
echo "Next steps:"
echo "1. Create central EventBridge rule on s3-remediation-bus"
echo "2. Attach Lambda as target"
echo "3. Add Lambda invoke permission"

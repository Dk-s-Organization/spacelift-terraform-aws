import os
import boto3
import logging
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)


# Convert AWS Region names to the short codes used in log bucket names.
def region_to_short(region_name):
    region_mapping = {
        "us-east-1": "use1",
        "us-east-2": "use2",
        "sa-east-1": "sae1",
        "us-west-2": "usw2",
        "ap-south-1": "aps1",
    }

    return region_mapping.get(region_name)


def lambda_handler(event, context):
    logger.info("Received event: %s", event)

    # 1. Extract the newly created S3 bucket name and its Region.
    try:
        event_detail = event["detail"]
        request_parameters = event_detail["requestParameters"]

        bucket_name = request_parameters["bucketName"]

        # Normally available in the EventBridge envelope.
        # Falls back to the CloudTrail event detail if required.
        region_name = event.get("region") or event_detail.get("awsRegion")

        if not region_name:
            raise ValueError("AWS Region is missing from the incoming event.")

        logger.info(
            "New bucket detected: %s in Region: %s",
            bucket_name,
            region_name,
        )

    except (KeyError, TypeError, ValueError) as error:
        logger.error(
            "Could not parse bucket name or Region from the incoming event: %s",
            str(error),
        )
        return {
            "statusCode": 400,
            "status": "FAILED",
            "reason": "Invalid EventBridge event structure",
        }

    # 2. Convert the AWS Region into the shortcode used in bucket names.
    region_short = region_to_short(region_name)

    if not region_short:
        logger.warning(
            "Region %s is not in the monitored scope. Skipping remediation.",
            region_name,
        )
        return {
            "statusCode": 200,
            "status": "SKIPPED",
            "reason": f"Region {region_name} is not monitored",
        }

    # 3. Read deployment-specific values from Lambda environment variables.
    bucket_prefix = os.environ.get(
        "LOG_TARGET_BUCKET_PREFIX",
        "dcli-regional-accesslogging-",
    )

    target_prefix = os.environ.get(
        "LOG_TARGET_FOLDER_PREFIX",
        "s3-access-logs/",
    )

    # Ensure the destination folder prefix ends with a slash.
    if target_prefix and not target_prefix.endswith("/"):
        target_prefix = f"{target_prefix}/"

    # Extract the AWS account ID from the Lambda function ARN.
    try:
        account_id = context.invoked_function_arn.split(":")[4]

        if not account_id:
            raise ValueError("Account ID is empty.")

    except (AttributeError, IndexError, ValueError) as error:
        logger.error(
            "Could not extract the AWS account ID from the Lambda context: %s",
            str(error),
        )
        raise

    # 4. Construct the regional S3 server access logging bucket name.
    target_regional_bucket = (
        f"{bucket_prefix}{account_id}-{region_short}"
    )

    logger.info(
        "Calculated logging destination for Region %s: s3://%s/%s",
        region_name,
        target_regional_bucket,
        target_prefix,
    )

    # 5. Do not enable access logging on any designated logging bucket.
    #
    # Using startswith protects every regional destination bucket, not only
    # the destination bucket for the current Region.
    if bucket_name.startswith(bucket_prefix):
        logger.info(
            "Bucket '%s' matches the logging destination prefix '%s'. "
            "Skipping remediation to prevent recursive access logging.",
            bucket_name,
            bucket_prefix,
        )

        return {
            "statusCode": 200,
            "status": "SKIPPED",
            "reason": "Bucket is a logging destination bucket",
            "bucket": bucket_name,
        }

    # Additional exact-name guardrail.
    if bucket_name == target_regional_bucket:
        logger.info(
            "Bucket '%s' is the designated regional logging destination. "
            "Skipping remediation.",
            bucket_name,
        )

        return {
            "statusCode": 200,
            "status": "SKIPPED",
            "reason": "Bucket is the regional logging destination",
            "bucket": bucket_name,
        }

    # 6. Create an S3 client in the source bucket's Region.
    s3_client = boto3.client(
        "s3",
        region_name=region_name,
    )

    # 7. Enable S3 server access logging using PartitionedPrefix.
    try:
        s3_client.put_bucket_logging(
            Bucket=bucket_name,
            ExpectedBucketOwner=account_id,
            BucketLoggingStatus={
                "LoggingEnabled": {
                    "TargetBucket": target_regional_bucket,
                    "TargetPrefix": target_prefix,
                    "TargetObjectKeyFormat": {
                        "PartitionedPrefix": {
                            "PartitionDateSource": "EventTime"
                        }
                    },
                }
            },
        )

        logger.info(
            "Successfully enabled server access logging for '%s'. "
            "Destination: s3://%s/%s. "
            "Object key format: PartitionedPrefix. "
            "Partition date source: EventTime.",
            bucket_name,
            target_regional_bucket,
            target_prefix,
        )

        # 8. Verify that the logging configuration was applied.
        logging_configuration = s3_client.get_bucket_logging(
            Bucket=bucket_name,
            ExpectedBucketOwner=account_id,
        )

        logging_enabled = logging_configuration.get("LoggingEnabled")

        if not logging_enabled:
            raise RuntimeError(
                f"Logging verification failed for bucket '{bucket_name}'."
            )

        logger.info(
            "Verified logging configuration for '%s': %s",
            bucket_name,
            logging_enabled,
        )

        return {
            "statusCode": 200,
            "status": "SUCCESS",
            "sourceBucket": bucket_name,
            "sourceRegion": region_name,
            "targetBucket": target_regional_bucket,
            "targetPrefix": target_prefix,
            "objectKeyFormat": "PartitionedPrefix",
            "partitionDateSource": "EventTime",
        }

    except ClientError as error:
        error_code = error.response.get(
            "Error", {}
        ).get(
            "Code", "Unknown"
        )

        error_message = error.response.get(
            "Error", {}
        ).get(
            "Message", str(error)
        )

        logger.exception(
            "Failed to configure server access logging for '%s'. "
            "Error code: %s. Error message: %s",
            bucket_name,
            error_code,
            error_message,
        )

        raise

    except Exception:
        logger.exception(
            "Unexpected error while configuring server access logging "
            "for bucket '%s'.",
            bucket_name,
        )

        raise

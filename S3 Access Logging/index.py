import os
import time
import boto3
import logging
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def resolve_region_shortcode(region_name):
    """Resolve an AWS Region to the corporate shortcode supplied by Terraform."""
    raw_mapping = os.environ.get("LOG_REGION_SHORTCODE_MAPPING", "")
    region_mapping = {}

    for pair in raw_mapping.split(","):
        pair = pair.strip()
        if not pair or ":" not in pair:
            continue
        region, shortcode = pair.split(":", 1)
        region_mapping[region.strip()] = shortcode.strip()

    shortcode = region_mapping.get(region_name)
    if shortcode:
        return shortcode

    # Fallback for an unexpected Region. Explicit mappings remain recommended.
    parts = region_name.split("-")
    if len(parts) >= 3:
        return f"{parts[0][0]}{parts[1][0]}{parts[2]}"

    return region_name.replace("-", "")


def normalize_bucket_region(location_constraint):
    """Normalize S3 GetBucketLocation/CreateBucket values."""
    if not location_constraint or location_constraint in ("us-standard", "global"):
        return "us-east-1"
    if location_constraint == "EU":
        return "eu-west-1"
    return location_constraint


def discover_bucket_region(bucket_name, account_id, event, event_detail):
    """Determine the actual bucket Region, including us-east-1 global endpoint cases."""
    request_parameters = event_detail.get("requestParameters") or {}
    create_configuration = (
        request_parameters.get("CreateBucketConfiguration")
        or request_parameters.get("createBucketConfiguration")
        or {}
    )

    event_location = (
        create_configuration.get("LocationConstraint")
        or create_configuration.get("locationConstraint")
    )

    candidates = [
        event_location,
        event_detail.get("awsRegion"),
        event.get("region"),
    ]

    # GetBucketLocation provides the authoritative location. Retry briefly because
    # CreateBucket and remediation occur close together.
    discovery_client = boto3.client("s3", region_name="us-east-1")
    last_error = None

    for attempt in range(1, 4):
        try:
            response = discovery_client.get_bucket_location(
                Bucket=bucket_name,
                ExpectedBucketOwner=account_id,
            )
            return normalize_bucket_region(response.get("LocationConstraint"))
        except ClientError as error:
            last_error = error
            logger.warning(
                "Bucket Region discovery attempt %s failed for '%s': %s",
                attempt,
                bucket_name,
                error.response.get("Error", {}).get("Code", "Unknown"),
            )
            if attempt < 3:
                time.sleep(2 ** attempt)

    for candidate in candidates:
        if candidate:
            fallback_region = normalize_bucket_region(candidate)
            logger.warning(
                "Using event-derived Region '%s' for '%s' after GetBucketLocation failed: %s",
                fallback_region,
                bucket_name,
                str(last_error),
            )
            return fallback_region

    raise ValueError(f"Could not determine the AWS Region for bucket '{bucket_name}'.")


def lambda_handler(event, context):
    logger.info("Received event: %s", event)

    try:
        event_detail = event["detail"]
        request_parameters = event_detail["requestParameters"]
        bucket_name = request_parameters["bucketName"]
        account_id = context.invoked_function_arn.split(":")[4]

        if not account_id:
            raise ValueError("Could not extract the AWS account ID from the Lambda ARN.")

        region_name = discover_bucket_region(
            bucket_name=bucket_name,
            account_id=account_id,
            event=event,
            event_detail=event_detail,
        )

        logger.info(
            "Processing bucket '%s' in authoritative Region '%s'.",
            bucket_name,
            region_name,
        )

    except (KeyError, TypeError, ValueError, AttributeError, IndexError) as error:
        logger.exception("Could not parse or resolve the incoming event: %s", str(error))
        return {
            "statusCode": 400,
            "status": "FAILED",
            "reason": str(error),
        }

    bucket_prefix = os.environ.get(
        "LOG_TARGET_BUCKET_PREFIX",
        "dcli-regional-accesslogging-",
    )
    target_prefix = os.environ.get(
        "LOG_TARGET_FOLDER_PREFIX",
        "s3-access-logs/",
    )
    partition_source = os.environ.get(
        "LOG_PARTITION_DATE_SOURCE",
        "EventTime",
    )
    object_key_format = os.environ.get(
        "LOG_OBJECT_KEY_FORMAT",
        "PartitionedPrefix",
    )
    enable_versioning = (
        os.environ.get("ENABLE_VERSIONING", "TRUE").upper() == "TRUE"
    )
    versioning_target_status = os.environ.get(
        "VERSIONING_TARGET_STATUS",
        "Enabled",
    )

    if target_prefix and not target_prefix.endswith("/"):
        target_prefix = f"{target_prefix}/"

    region_short = resolve_region_shortcode(region_name)
    target_regional_bucket = f"{bucket_prefix}{account_id}-{region_short}"

    # Never enable access logging on any destination logging bucket.
    if bucket_name.startswith(bucket_prefix):
        logger.info(
            "Bucket '%s' is a logging destination bucket. Skipping remediation.",
            bucket_name,
        )
        return {
            "statusCode": 200,
            "status": "SKIPPED",
            "reason": "Bucket is a system logging destination",
            "sourceBucket": bucket_name,
            "sourceRegion": region_name,
        }

    s3_client = boto3.client("s3", region_name=region_name)

    remediation_summary = {
        "access_logging": "NOT_ATTEMPTED",
        "versioning": "NOT_ATTEMPTED",
    }

    # Enable and verify S3 server access logging.
    try:
        logging_enabled = {
            "TargetBucket": target_regional_bucket,
            "TargetPrefix": target_prefix,
        }

        if object_key_format == "PartitionedPrefix":
            logging_enabled["TargetObjectKeyFormat"] = {
                "PartitionedPrefix": {
                    "PartitionDateSource": partition_source,
                }
            }
        elif object_key_format == "SimplePrefix":
            logging_enabled["TargetObjectKeyFormat"] = {
                "SimplePrefix": {}
            }
        else:
            raise ValueError(
                "LOG_OBJECT_KEY_FORMAT must be PartitionedPrefix or SimplePrefix."
            )

        s3_client.put_bucket_logging(
            Bucket=bucket_name,
            ExpectedBucketOwner=account_id,
            BucketLoggingStatus={"LoggingEnabled": logging_enabled},
        )

        logging_configuration = s3_client.get_bucket_logging(
            Bucket=bucket_name,
            ExpectedBucketOwner=account_id,
        )

        applied_logging = logging_configuration.get("LoggingEnabled")
        if not applied_logging:
            raise RuntimeError(
                f"Logging verification failed for bucket '{bucket_name}'."
            )

        remediation_summary["access_logging"] = "Enabled"
        logger.info(
            "Verified access logging for '%s' to 's3://%s/%s'.",
            bucket_name,
            target_regional_bucket,
            target_prefix,
        )

    except ClientError as error:
        error_code = error.response.get("Error", {}).get("Code", "Unknown")
        remediation_summary["access_logging"] = f"ERROR:{error_code}"
        logger.exception(
            "Access logging failed for bucket '%s' using destination '%s'.",
            bucket_name,
            target_regional_bucket,
        )
    except Exception as error:
        remediation_summary["access_logging"] = "ERROR:UnexpectedError"
        logger.exception(
            "Unexpected access logging failure for bucket '%s': %s",
            bucket_name,
            str(error),
        )

    # Enable and verify bucket versioning independently.
    if enable_versioning:
        try:
            s3_client.put_bucket_versioning(
                Bucket=bucket_name,
                ExpectedBucketOwner=account_id,
                VersioningConfiguration={"Status": versioning_target_status},
            )

            versioning_configuration = s3_client.get_bucket_versioning(
                Bucket=bucket_name,
                ExpectedBucketOwner=account_id,
            )

            if versioning_configuration.get("Status") != versioning_target_status:
                raise RuntimeError(
                    f"Versioning verification failed for bucket '{bucket_name}'."
                )

            remediation_summary["versioning"] = versioning_target_status
            logger.info(
                "Verified versioning state '%s' for bucket '%s'.",
                versioning_target_status,
                bucket_name,
            )

        except ClientError as error:
            error_code = error.response.get("Error", {}).get("Code", "Unknown")
            remediation_summary["versioning"] = f"ERROR:{error_code}"
            logger.exception("Versioning failed for bucket '%s'.", bucket_name)
        except Exception as error:
            remediation_summary["versioning"] = "ERROR:UnexpectedError"
            logger.exception(
                "Unexpected versioning failure for bucket '%s': %s",
                bucket_name,
                str(error),
            )
    else:
        remediation_summary["versioning"] = "SKIPPED"

    overall_status = (
        "SUCCESS"
        if remediation_summary["access_logging"] == "Enabled"
        and (
            not enable_versioning
            or remediation_summary["versioning"] == versioning_target_status
        )
        else "PARTIAL_FAILURE"
    )

    return {
        "statusCode": 200 if overall_status == "SUCCESS" else 207,
        "status": overall_status,
        "sourceBucket": bucket_name,
        "sourceRegion": region_name,
        "targetBucket": target_regional_bucket,
        "targetPrefix": target_prefix,
        "summary": remediation_summary,
    }

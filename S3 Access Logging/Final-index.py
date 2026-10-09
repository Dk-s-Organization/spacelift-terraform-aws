import os
import boto3
import logging
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def resolve_region_shortcode(region_name):
    """
    Dynamically maps region names to your organization's custom shortcodes.
    Falls back to a comma-separated list or mapping parsed directly from 
    the LOG_REGION_SHORTCODE_MAPPING environment variable.
    Format example: "us-east-1:use1,us-east-2:use2,eu-west-1:ew1"
    """
    raw_mapping = os.environ.get("LOG_REGION_SHORTCODE_MAPPING", "")
    
    # Parse the custom environment mapping dynamically
    region_mapping = {}
    if raw_mapping:
        try:
            for pair in raw_mapping.split(","):
                if ":" in pair:
                    k, v = pair.split(":", 1)
                    region_mapping[k.strip()] = v.strip()
        except Exception as e:
            logger.error("Failed to parse dynamic region mapping from env: %s", str(e))

    # Dynamic fallback check
    shortcode = region_mapping.get(region_name)
    if not shortcode:
        # Fallback approach: strips hyphens and takes parts to build standard code natively
        # e.g., us-east-1 -> use1, sa-east-1 -> sae1
        parts = region_name.split("-")
        if len(parts) >= 3:
            shortcode = f"{parts[0][0]}{parts[1][0]}{parts[2]}"
        else:
            shortcode = region_name.replace("-", "")
            
    return shortcode


def lambda_handler(event, context):
    logger.info("Received event: %s", event)

    # 1. Extract newly created S3 bucket configurations dynamically
    try:
        event_detail = event["detail"]
        request_parameters = event_detail["requestParameters"]

        bucket_name = request_parameters["bucketName"]
        region_name = event.get("region") or event_detail.get("awsRegion")

        if not region_name:
            raise ValueError("AWS Region is missing from the incoming event.")

        logger.info("New bucket detected: %s in Region: %s", bucket_name, region_name)

    except (KeyError, TypeError, ValueError) as error:
        logger.error("Could not parse bucket name or Region from event structure: %s", str(error))
        return {
            "statusCode": 400,
            "status": "FAILED",
            "reason": "Invalid EventBridge event structure",
        }

    # 2. Get Monitored Scope and Regional shortcodes dynamically
    monitored_regions_env = os.environ.get("MONITORED_REGIONS", "")
    if monitored_regions_env:
        monitored_regions = [r.strip() for r in monitored_regions_env.split(",") if r.strip()]
        if region_name not in monitored_regions:
            logger.warning("Region %s is outside the monitored scope. Skipping remediation.", region_name)
            return {
                "statusCode": 200,
                "status": "SKIPPED",
                "reason": f"Region {region_name} is not inside monitored scope environment configuration.",
            }

    region_short = resolve_region_shortcode(region_name)

    # 3. Read environment execution configs dynamically with zero logic-hardcoding
    bucket_prefix = os.environ.get("LOG_TARGET_BUCKET_PREFIX", "dcli-regional-accesslogging-")
    target_prefix = os.environ.get("LOG_TARGET_FOLDER_PREFIX", "s3-access-logs/")
    partition_source = os.environ.get("LOG_PARTITION_DATE_SOURCE", "EventTime")
    object_key_format = os.environ.get("LOG_OBJECT_KEY_FORMAT", "PartitionedPrefix") # e.g. PartitionedPrefix or SimplePrefix
    enable_versioning_flag = os.environ.get("ENABLE_VERSIONING", "TRUE").upper() == "TRUE"

    if target_prefix and not target_prefix.endswith("/"):
        target_prefix = f"{target_prefix}/"

    # Dynamic extraction of the active AWS Account ID from context
    try:
        account_id = context.invoked_function_arn.split(":")[4]
        if not account_id:
            raise ValueError("Extracted Account ID evaluation is empty.")
    except (AttributeError, IndexError, ValueError) as error:
        logger.error("Could not dynamically extract AWS Account ID from context: %s", str(error))
        raise

    # 4. Construct regional logging landing location variables dynamically
    target_regional_bucket = f"{bucket_prefix}{account_id}-{region_short}"

    logger.info(
        "Calculated logging destination for Region %s: s3://%s/%s",
        region_name, target_regional_bucket, target_prefix
    )

    # 5. Recursive loop prevention guardrails 
    if bucket_name.startswith(bucket_prefix) or bucket_name == target_regional_bucket:
        logger.info(
            "Bucket '%s' matches infrastructure regional logging destinations. Skipping remediation to prevent recursive loops.",
            bucket_name
        )
        return {
            "statusCode": 200,
            "status": "SKIPPED",
            "reason": "Bucket target is flagged as an operational infrastructure logging asset",
            "bucket": bucket_name,
        }

    # 6. Instantiate global AWS localized clients dynamically
    s3_client = boto3.client("s3", region_name=region_name)

    try:
        # 7. Dynamically structured Server Access Logging payload
        logging_status_payload = {
            "LoggingEnabled": {
                "TargetBucket": target_regional_bucket,
                "TargetPrefix": target_prefix,
            }
        }
        
        # Inject structural choices gracefully dynamically based on variable selection
        if object_key_format == "PartitionedPrefix":
            logging_status_payload["LoggingEnabled"]["TargetObjectKeyFormat"] = {
                "PartitionedPrefix": {"PartitionDateSource": partition_source}
            }
        elif object_key_format == "SimplePrefix":
            logging_status_payload["LoggingEnabled"]["TargetObjectKeyFormat"] = {
                "SimplePrefix": {}
            }

        s3_client.put_bucket_logging(
            Bucket=bucket_name,
            ExpectedBucketOwner=account_id,
            BucketLoggingStatus=logging_status_payload,
        )
        logger.info("Successfully enabled server access logging configurations for target '%s'.", bucket_name)

        # 8. Dynamic validation check for active Logging
        logging_configuration = s3_client.get_bucket_logging(Bucket=bucket_name, ExpectedBucketOwner=account_id)
        if not logging_configuration.get("LoggingEnabled"):
            raise RuntimeError(f"Logging configuration active state verification failed for '{bucket_name}'.")

        # 9. Dynamic configuration for Bucket Versioning controls
        if enable_versioning_flag:
            versioning_status_config = os.environ.get("VERSIONING_TARGET_STATUS", "Enabled") # Enabled or Suspended
            
            s3_client.put_bucket_versioning(
                Bucket=bucket_name,
                ExpectedBucketOwner=account_id,
                VersioningConfiguration={"Status": versioning_status_config}
            )
            logger.info("Successfully requested versioning change to '%s' state for bucket '%s'.", versioning_status_config, bucket_name)

            # 10. Dynamic validation check for active Versioning
            versioning_status = s3_client.get_bucket_versioning(Bucket=bucket_name, ExpectedBucketOwner=account_id)
            if versioning_status.get("Status") != versioning_status_config:
                raise RuntimeError(f"Versioning active state verification failed for '{bucket_name}'. Expected: {versioning_status_config}")
            
            logger.info("Verified versioning state configuration for '%s': %s", bucket_name, versioning_status_config)
        else:
            logger.info("Bucket versioning application skipped based on ENABLE_VERSIONING flag parameters.")

        return {
            "statusCode": 200,
            "status": "SUCCESS",
            "sourceBucket": bucket_name,
            "sourceRegion": region_name,
            "targetBucket": target_regional_bucket,
            "targetPrefix": target_prefix,
            "objectKeyFormat": object_key_format,
            "versioningApplied": str(enable_versioning_flag)
        }

    except ClientError as error:
        error_code = error.response.get("Error", {}).get("Code", "Unknown")
        error_message = error.response.get("Error", {}).get("Message", str(error))
        logger.exception(
            "Failed processing remediation policy execution for bucket '%s'. Error code: %s. Message: %s",
            bucket_name, error_code, error_message
        )
        raise
    except Exception:
        logger.exception("Unexpected structural exception processing operations for bucket '%s'.", bucket_name)
        raise

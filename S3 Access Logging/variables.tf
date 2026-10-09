variable "central_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS Region that hosts the central EventBridge bus and remediation Lambda."
}

variable "log_target_bucket_prefix" {
  type        = string
  default     = "dcli-regional-accesslogging-"
  description = "Prefix assigned to regional S3 access logging destination buckets."
}

variable "log_target_folder_prefix" {
  type        = string
  default     = "s3-access-logs/"
  description = "Destination prefix used for S3 server access log objects."
}

variable "monitored_regions" {
  type        = map(string)
  description = "Mapping of monitored AWS Regions to corporate Region shortcodes."

  default = {
    "us-east-1"  = "use1"
    "us-east-2"  = "use2"
    "sa-east-1"  = "sae1"
    "us-west-2"  = "usw2"
    "ap-south-1" = "aps1"
  }
}

variable "authorized_account_ids" {
  type        = list(string)
  default     = ["307946672793"]
  description = "AWS account IDs permitted to put events on the central EventBridge bus."
}

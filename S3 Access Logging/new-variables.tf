variable "log_target_bucket_prefix" {
  type        = string
  default     = "dcli-regional-accesslogging-"
  description = "The prefix string assigned to central access log targets."
}

variable "log_target_folder_prefix" {
  type        = string
  default     = "s3-access-logs/"
  description = "The directory path structure inside the logging bucket."
}

# NEW: Scalable collection for all target regions and their custom shortcodes
variable "monitored_regions" {
  type = map(string)
  default = {
    "us-east-1"  = "use1"
    "us-east-2"  = "use2"
    "sa-east-1"  = "sae1"
    "us-west-2"  = "usw2"
    "ap-south-1" = "aps1"
    # To add a new region in the future, just append it right here:
    # "eu-west-1" = "ew1"
  }
}

# NEW: Scalable collection for active multi-account compliance scope
variable "authorized_account_ids" {
  type        = list(string)
  default     = ["112233445566"] 
  description = "List of corporate AWS accounts allowed to forward event streams to this bus."
}

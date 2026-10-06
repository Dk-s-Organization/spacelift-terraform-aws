variable "log_target_bucket_prefix" {
  type        = string
  default     = "dcli-regional-accesslogging-"
  description = "The prefix string assigned to your centralized regional access logging buckets."
}

variable "log_target_folder_prefix" {
  type        = string
  default     = "s3-access-logs/"
  description = "The directory path structure inside the logging bucket where files will drop."
}

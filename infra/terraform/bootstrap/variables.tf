variable "region" {
  description = "AWS region for the state bucket. Must match the `region` in each env's backend.tf."
  type        = string
  default     = "ap-south-1"
}

variable "bucket_name" {
  description = "State bucket name. Null means tdb-bookings-tfstate-<account id>, which is globally unique per account."
  type        = string
  default     = null

  validation {
    condition     = var.bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid S3 bucket name (3-63 chars, lowercase letters, digits, dots, hyphens)."
  }
}

variable "kms_alias" {
  description = "Alias of the CMK that encrypts state. The env backends reference it as kms_key_id, so keep them in step."
  type        = string
  default     = "alias/tdb-bookings-tfstate"

  validation {
    condition     = can(regex("^alias/[a-zA-Z0-9/_-]+$", var.kms_alias)) && !startswith(var.kms_alias, "alias/aws/")
    error_message = "kms_alias must look like alias/<name> and must not use the reserved alias/aws/ prefix."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days an overwritten state version is kept before it expires. This is the recovery window for a bad apply."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 30
    error_message = "Keep at least 30 days of old state versions so a bad apply can be rolled back."
  }
}

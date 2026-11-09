# Environment settings are fixed in locals.tf (reviewed in PRs, no tfvars to forget). The only input is the
# account guard, which is not secret but differs per organisation.
variable "allowed_account_ids" {
  description = "AWS account IDs this env may be applied to. Null disables the guard (e.g. for offline validate)."
  type        = list(string)
  default     = null

  validation {
    condition     = var.allowed_account_ids == null || alltrue([for id in coalesce(var.allowed_account_ids, []) : can(regex("^[0-9]{12}$", id))])
    error_message = "allowed_account_ids must be 12-digit AWS account IDs."
  }
}

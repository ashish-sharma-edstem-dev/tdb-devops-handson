variable "name" {
  description = "Name prefix for every resource, e.g. tdb-bookings-prod."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,40}$", var.name))
    error_message = "name must be 3-41 chars of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "cidr" {
  description = "VPC CIDR. Must be a /16: subnets are carved as /24s at fixed offsets (public .0-2, app .10-12, db .20-22)."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && try(split("/", var.cidr)[1] == "16", false)
    error_message = "cidr must be a valid IPv4 /16, e.g. 10.0.0.0/16."
  }
}

variable "azs" {
  description = "Availability zones to spread subnets over, in order. 3 for prod (survives one AZ loss), 2 for dev."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2 && length(var.azs) <= 3 && length(distinct(var.azs)) == length(var.azs)
    error_message = "azs must list 2 or 3 distinct availability zones."
  }
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway instead of one per AZ. Cheaper, but an outage of that AZ cuts egress for all. Dev only."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for VPC flow logs."
  type        = number
  default     = 365

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_log_retention_days)
    error_message = "flow_log_retention_days must be a value CloudWatch Logs accepts (e.g. 30, 90, 365)."
  }
}

variable "tags" {
  description = "Extra tags for every resource (provider default_tags already carry Environment/Service/ManagedBy)."
  type        = map(string)
  default     = {}
}

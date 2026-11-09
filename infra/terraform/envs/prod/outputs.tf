output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "azs" {
  description = "AZs in use."
  value       = module.network.azs
}

output "public_subnet_ids" {
  description = "Public subnets (ALB, NAT)."
  value       = module.network.public_subnet_ids
}

output "app_subnet_ids" {
  description = "Private app subnets for EKS nodes / pods."
  value       = module.network.app_subnet_ids
}

output "db_subnet_ids" {
  description = "Private DB subnets."
  value       = module.network.db_subnet_ids
}

output "app_security_group_id" {
  description = "sg-app: attach to tdb-bookings workloads to reach the database."
  value       = module.network.app_security_group_id
}

output "db_endpoint" {
  description = "PostgreSQL endpoint (private DNS)."
  value       = module.postgres.endpoint
}

output "db_port" {
  description = "PostgreSQL port."
  value       = module.postgres.port
}

output "db_master_secret_arn" {
  description = "Secrets Manager ARN of the master credentials, for the External Secrets Operator SecretStore."
  value       = module.postgres.master_user_secret_arn
}

output "db_kms_key_arn" {
  description = "CMK the secret is encrypted with; the ESO role needs kms:Decrypt on it."
  value       = module.postgres.kms_key_arn
}

output "subnets" {
  description = "Subnets by tier with AZ and CIDR."
  value       = module.network.subnets
}

output "routing" {
  description = "Default routes and route table per subnet, by tier."
  value       = module.network.routing
}

output "nat_gateway_ids" {
  description = "NAT gateways."
  value       = module.network.nat_gateway_ids
}

output "db_security_posture" {
  description = "Database settings the requirements depend on."
  value       = module.postgres.security_posture
}

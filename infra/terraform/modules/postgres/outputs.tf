output "endpoint" {
  description = "DNS name of the instance. In Multi-AZ it follows the primary on failover."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "PostgreSQL port."
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "Initial database name."
  value       = aws_db_instance.this.db_name
}

output "master_user_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credentials. External Secrets Operator reads this."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "sg-db."
  value       = aws_security_group.db.id
}

output "kms_key_arn" {
  description = "CMK for storage, backups, Performance Insights, the master secret and logs. ESO's role needs kms:Decrypt on it."
  value       = aws_kms_key.db.arn
}

output "instance_arn" {
  description = "DB instance ARN."
  value       = aws_db_instance.this.arn
}

output "security_posture" {
  description = "The settings the requirements depend on, read back from the planned resources. Used by tests/ and handy in reviews."
  value = {
    publicly_accessible         = aws_db_instance.this.publicly_accessible
    multi_az                    = aws_db_instance.this.multi_az
    deletion_protection         = aws_db_instance.this.deletion_protection
    storage_encrypted           = aws_db_instance.this.storage_encrypted
    manage_master_user_password = aws_db_instance.this.manage_master_user_password
    backup_retention_period     = aws_db_instance.this.backup_retention_period
    skip_final_snapshot         = aws_db_instance.this.skip_final_snapshot
    db_subnet_ids               = aws_db_subnet_group.this.subnet_ids
    vpc_security_group_ids      = aws_db_instance.this.vpc_security_group_ids
    db_security_group_id        = aws_security_group.db.id
    force_ssl                   = one([for p in aws_db_parameter_group.this.parameter : p.value if p.name == "rds.force_ssl"])
    ingress_rules = [for r in aws_vpc_security_group_ingress_rule.db_from_allowed : {
      source_security_group_id = r.referenced_security_group_id
      cidr_ipv4                = r.cidr_ipv4
      cidr_ipv6                = r.cidr_ipv6
      prefix_list_id           = r.prefix_list_id
      from_port                = r.from_port
      to_port                  = r.to_port
    }]
  }
}

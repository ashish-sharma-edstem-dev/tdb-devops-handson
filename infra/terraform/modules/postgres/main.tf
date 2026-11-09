data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  major_version = split(".", var.engine_version)[0]

  # RDS writes exported logs to /aws/rds/instance/<id>/<type>. Creating the groups first lets us set KMS and
  # retention; otherwise RDS creates them unencrypted with no expiry.
  log_exports      = ["postgresql", "upgrade"]
  log_group_prefix = "/aws/rds/instance/${var.name}"
}

# ---------------------------------------------------------------------------------------------------------------------
# One CMK for storage, snapshots, Performance Insights, the master-password secret and exported logs.
# ---------------------------------------------------------------------------------------------------------------------
data "aws_iam_policy_document" "db_key" {
  #checkov:skip=CKV_AWS_109:Key policy: "*" in a key policy means this key only, and admin rights stay with the account root so IAM policies govern access.
  #checkov:skip=CKV_AWS_111:Key policy: "*" in a key policy means this key only; the logs grant is pinned to this instance's log groups by encryption context.
  #checkov:skip=CKV_AWS_356:Key policy: "*" in a key policy means this key only, not every resource.
  statement {
    sid       = "AccountAdministersKeyThroughIAM"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchLogsUseForThisInstanceLogsOnly"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_prefix}/*"]
    }
  }
}

resource "aws_kms_key" "db" {
  description             = "Encrypts ${var.name} PostgreSQL storage, backups, Performance Insights, master secret and logs"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.db_key.json

  tags = var.tags
}

resource "aws_kms_alias" "db" {
  name          = "alias/${var.name}-postgres"
  target_key_id = aws_kms_key.db.key_id
}

# ---------------------------------------------------------------------------------------------------------------------
# Network placement: DB subnets only, ingress 5432 only from the allowed security groups, no egress rules.
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_db_subnet_group" "this" {
  name        = var.name
  description = "Private DB subnets for ${var.name} (no internet route)"
  subnet_ids  = var.db_subnet_ids

  tags = var.tags
}

# No egress block: Terraform removes AWS's default allow-all egress rule, so the database cannot open connections
# out. Replies to inbound connections still flow (security groups are stateful).
resource "aws_security_group" "db" {
  # name_prefix, not name: with create_before_destroy a fixed name would collide with the group being replaced.
  name_prefix = "${var.name}-db-"
  description = "PostgreSQL for ${var.name}: 5432 from the app security group only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_allowed" {
  for_each = var.allowed_security_groups

  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = each.value
}

# ---------------------------------------------------------------------------------------------------------------------
# Parameters: TLS required, slow / DDL / lock / connection logging.
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-pg${local.major_version}-"
  family      = "postgres${local.major_version}"
  description = "tdb-bookings PostgreSQL ${local.major_version}: TLS only, query logging"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "ssl_min_protocol_version"
    value = "TLSv1.2"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_lock_waits"
    value = "1"
  }

  parameter {
    name  = "log_temp_files"
    value = "10240"
  }

  tags = var.tags

  # A major-version upgrade needs a new family: create the new group before the old one is removed.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "db" {
  for_each = toset(local.log_exports)

  name              = "${local.log_group_prefix}/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.db.arn

  tags = var.tags
}

# ---------------------------------------------------------------------------------------------------------------------
# Enhanced Monitoring (OS-level metrics every monitoring_interval seconds).
# ---------------------------------------------------------------------------------------------------------------------
data "aws_iam_policy_document" "monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    # Only this DB instance's monitoring may assume the role (confused-deputy protection).
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:rds:${local.region}:${local.account_id}:db:${var.name}"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name               = "${var.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------------------------------------------------------------------------------------------------------------------
# The instance.
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_157:multi_az is an input: true in prod (asserted by tests/prod.tftest.hcl), false in dev only to save cost.
  #checkov:skip=CKV_AWS_293:deletion_protection is an input: true in prod (asserted by tests/prod.tftest.hcl), false in dev so the env can be torn down.
  identifier = var.name

  engine                      = "postgres"
  engine_version              = var.engine_version
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  instance_class              = var.instance_class
  parameter_group_name        = aws_db_parameter_group.this.name

  db_name                             = var.database_name
  username                            = var.master_username
  manage_master_user_password         = true
  master_user_secret_kms_key_id       = aws_kms_key.db.arn
  iam_database_authentication_enabled = true
  port                                = 5432

  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.db.arn

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  network_type           = "IPV4"
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period  = var.backup_retention_days
  backup_window            = var.backup_window
  maintenance_window       = var.maintenance_window
  copy_tags_to_snapshot    = true
  delete_automated_backups = false
  deletion_protection      = var.deletion_protection
  skip_final_snapshot      = false
  # Unique per instance lifetime: a fixed name would make the second destroy of a recreated env fail with
  # DBSnapshotAlreadyExists. Set once at create and ignored afterwards, so plans stay clean.
  final_snapshot_identifier = "${var.name}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.db.arn
  performance_insights_retention_period = 7

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null

  enabled_cloudwatch_logs_exports = local.log_exports

  # Parameter and instance changes wait for the maintenance window instead of restarting prod mid-day.
  apply_immediately = false

  tags = var.tags

  depends_on = [
    aws_cloudwatch_log_group.db,
    aws_iam_role_policy_attachment.monitoring,
  ]

  lifecycle {
    ignore_changes = [final_snapshot_identifier]

    precondition {
      condition     = var.max_allocated_storage > var.allocated_storage
      error_message = "max_allocated_storage must be greater than allocated_storage, or storage autoscaling is off."
    }
  }
}

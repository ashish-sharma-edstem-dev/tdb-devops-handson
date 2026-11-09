data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  az_count  = length(var.azs)
  nat_count = var.single_nat_gateway ? 1 : local.az_count

  # Fixed /24 offsets inside the /16, so the layout matches docs/architecture: 10.0.0-2 public, 10.0.10-12 app,
  # 10.0.20-22 db. Adding an AZ later appends a subnet instead of renumbering the existing ones.
  public_cidrs = [for i in range(local.az_count) : cidrsubnet(var.cidr, 8, i)]
  app_cidrs    = [for i in range(local.az_count) : cidrsubnet(var.cidr, 8, 10 + i)]
  db_cidrs     = [for i in range(local.az_count) : cidrsubnet(var.cidr, 8, 20 + i)]

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

# Nothing may use the default security group: it is emptied so a resource created without an explicit SG gets no
# access at all instead of "everything in the same SG".
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-default-unused" })
}

# Subnets are all explicitly associated below; the main route table gets no routes so a future subnet that is
# forgotten is isolated rather than accidentally public.
resource "aws_default_route_table" "this" {
  default_route_table_id = aws_vpc.this.default_route_table_id

  tags = merge(var.tags, { Name = "${var.name}-main-unused" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = var.name })
}

# ---------------------------------------------------------------------------------------------------------------------
# Public tier: load balancers and NAT gateways only. No workload gets a public IP.
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.azs[count.index]
  cidr_block              = local.public_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name                     = "${var.name}-public-${var.azs[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-nat-${var.azs[count.index]}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, { Name = "${var.name}-${var.azs[count.index]}" })

  depends_on = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------------------------------------------------
# Private app tier: EKS nodes / pods. Egress through the NAT gateway in the SAME AZ, so losing one AZ never cuts
# egress for the others (unless single_nat_gateway, dev only).
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_subnet" "app" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = var.azs[count.index]
  cidr_block        = local.app_cidrs[count.index]

  tags = merge(var.tags, {
    Name                              = "${var.name}-app-${var.azs[count.index]}"
    Tier                              = "app"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_route_table" "app" {
  count = local.az_count

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-app-${var.azs[count.index]}" })
}

resource "aws_route" "app_nat" {
  count = local.az_count

  route_table_id         = aws_route_table.app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "app" {
  count = local.az_count

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# ---------------------------------------------------------------------------------------------------------------------
# Private DB tier: no route out at all. The route table has only the implicit VPC-local route, so nothing in these
# subnets can reach, or be reached from, the internet even if a security group were misconfigured.
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_subnet" "db" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = var.azs[count.index]
  cidr_block        = local.db_cidrs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-db-${var.azs[count.index]}"
    Tier = "db"
  })
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-db" })
}

resource "aws_route_table_association" "db" {
  count = local.az_count

  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# ---------------------------------------------------------------------------------------------------------------------
# Workload security group (sg-app). EKS nodes / pods running tdb-bookings attach it; the database admits 5432 only
# from it. Ingress (from the ALB) is added by the platform that owns the ALB, which is outside this stack.
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_security_group" "app" {
  #checkov:skip=CKV2_AWS_5:Attached by the EKS node group / pods, which are provisioned outside this stack (see README, Out of scope).
  name        = "${var.name}-app"
  description = "tdb-bookings workloads; the only source the database accepts"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-app" })
}

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS out via NAT: image pulls, AWS APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_postgres" {
  for_each = toset(local.db_cidrs)

  security_group_id = aws_security_group.app.id
  description       = "PostgreSQL to the DB subnets only"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = each.value
}

# ---------------------------------------------------------------------------------------------------------------------
# VPC flow logs → CloudWatch Logs, encrypted with a CMK. Rejected and accepted traffic, for incident forensics.
# ---------------------------------------------------------------------------------------------------------------------
locals {
  flow_log_group_name = "/aws/vpc-flow-logs/${var.name}"
  flow_log_group_arn  = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.flow_log_group_name}"
}

data "aws_iam_policy_document" "flow_logs_key" {
  #checkov:skip=CKV_AWS_109:Key policy: "*" in a key policy means this key only, and admin rights stay with the account root so IAM policies govern access.
  #checkov:skip=CKV_AWS_111:Key policy: "*" in a key policy means this key only; the logs grant is pinned to one log group by encryption context.
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
    sid       = "CloudWatchLogsUseForFlowLogGroupOnly"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = [local.flow_log_group_arn]
    }
  }
}

resource "aws_kms_key" "flow_logs" {
  description             = "Encrypts VPC flow logs for ${var.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.flow_logs_key.json

  tags = var.tags
}

resource "aws_kms_alias" "flow_logs" {
  name          = "alias/${var.name}-flow-logs"
  target_key_id = aws_kms_key.flow_logs.key_id
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = local.flow_log_group_name
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = aws_kms_key.flow_logs.arn

  tags = var.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    # Confused-deputy protection: only flow logs in this account may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:vpc-flow-log/*"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    sid = "WriteToThisLogGroupOnly"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn

  tags = merge(var.tags, { Name = var.name })
}

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "AZs in use, index-aligned with every subnet list."
  value       = var.azs
}

output "public_subnet_ids" {
  description = "Public subnets (ALB, NAT), one per AZ."
  value       = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  description = "Private app subnets (EKS nodes / pods), one per AZ."
  value       = aws_subnet.app[*].id
}

output "db_subnet_ids" {
  description = "Private DB subnets (no internet route), one per AZ."
  value       = aws_subnet.db[*].id
}

output "db_subnet_cidrs" {
  description = "CIDRs of the DB subnets."
  value       = aws_subnet.db[*].cidr_block
}

output "nat_gateway_ids" {
  description = "NAT gateways: one per AZ, or one when single_nat_gateway."
  value       = aws_nat_gateway.this[*].id
}

output "nat_public_ips" {
  description = "Egress IPs, for allow-listing at third parties."
  value       = aws_eip.nat[*].public_ip
}

output "app_security_group_id" {
  description = "sg-app: attach to tdb-bookings workloads; the database admits only this group."
  value       = aws_security_group.app.id
}

output "subnets" {
  description = "Every subnet by tier with its AZ and CIDR, for reviews and tests/ (prove the layout matches docs/architecture)."
  value = {
    for tier, list in { public = aws_subnet.public, app = aws_subnet.app, db = aws_subnet.db } :
    tier => [for s in list : { id = s.id, az = s.availability_zone, cidr = s.cidr_block }]
  }
}

output "routing" {
  description = "Default (0.0.0.0/0) routes and the route table of each subnet, by tier. Proves the DB tier has no internet path and each AZ uses its own NAT."
  value = {
    default_routes = concat(
      [{ route_table_id = aws_route.public_internet.route_table_id, target = aws_route.public_internet.gateway_id }],
      [for r in aws_route.app_nat : { route_table_id = r.route_table_id, target = r.nat_gateway_id }],
    )
    public_route_table_ids = aws_route_table_association.public[*].route_table_id
    app_route_table_ids    = aws_route_table_association.app[*].route_table_id
    db_route_table_ids     = aws_route_table_association.db[*].route_table_id
    nat_gateway_subnet_ids = aws_nat_gateway.this[*].subnet_id
    internet_gateway_id    = aws_internet_gateway.this.id
  }
}

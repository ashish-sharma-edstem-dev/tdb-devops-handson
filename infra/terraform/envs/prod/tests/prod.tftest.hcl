# Proves the prod requirements against the real composition (this root, modules/network, modules/postgres) without
# AWS: the provider is mocked, so nothing is created and no credentials are used. `command = apply` here means
# "apply to the mock" — it is needed so generated IDs exist and route -> NAT -> subnet wiring can be compared.

mock_provider "aws" {
  source = "../../tests/mocks"
}

run "layout_matches_architecture" {
  command = plan

  assert {
    condition     = output.azs == tolist(["ap-south-1a", "ap-south-1b", "ap-south-1c"])
    error_message = "Prod must span three AZs."
  }

  assert {
    condition     = [for s in output.subnets.public : s.cidr] == ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
    error_message = "Public subnets must be 10.0.0-2.0/24 (docs/architecture)."
  }

  assert {
    condition     = [for s in output.subnets.app : s.cidr] == ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
    error_message = "Private app subnets must be 10.0.10-12.0/24 (docs/architecture)."
  }

  assert {
    condition     = [for s in output.subnets.db : s.cidr] == ["10.0.20.0/24", "10.0.21.0/24", "10.0.22.0/24"]
    error_message = "Private DB subnets must be 10.0.20-22.0/24 (docs/architecture)."
  }

  assert {
    condition     = alltrue([for tier in ["public", "app", "db"] : tolist([for s in output.subnets[tier] : s.az]) == output.azs])
    error_message = "Every tier must have exactly one subnet in each AZ."
  }

  assert {
    condition     = output.db_security_posture.publicly_accessible == false
    error_message = "The database must not be publicly accessible."
  }

  assert {
    condition     = output.db_security_posture.multi_az == true
    error_message = "Prod database must be Multi-AZ to survive an AZ loss."
  }

  assert {
    condition     = output.db_security_posture.deletion_protection && !output.db_security_posture.skip_final_snapshot
    error_message = "Prod database needs deletion protection and a final snapshot."
  }

  assert {
    condition     = output.db_security_posture.storage_encrypted && output.db_security_posture.manage_master_user_password
    error_message = "Storage must be encrypted and the master password managed by Secrets Manager."
  }

  assert {
    condition     = output.db_security_posture.backup_retention_period == 30
    error_message = "Prod keeps 30 days of backups."
  }

  assert {
    condition     = output.db_security_posture.force_ssl == "1"
    error_message = "rds.force_ssl must be 1."
  }
}

run "survives_one_az_and_db_is_private" {
  command = apply

  assert {
    condition     = length(output.nat_gateway_ids) == 3 && length(distinct(output.nat_gateway_ids)) == 3
    error_message = "Prod needs one NAT gateway per AZ."
  }

  assert {
    condition     = output.routing.nat_gateway_subnet_ids == [for s in output.subnets.public : s.id]
    error_message = "NAT gateway i must sit in the public subnet of AZ i."
  }

  assert {
    condition = alltrue([
      for i, rt in output.routing.app_route_table_ids :
      [for r in output.routing.default_routes : r.target if r.route_table_id == rt] == [output.nat_gateway_ids[i]]
    ])
    error_message = "Each private app subnet must default-route to the NAT gateway in its own AZ."
  }

  assert {
    condition     = length(distinct(output.routing.app_route_table_ids)) == 3
    error_message = "Each AZ's app subnet needs its own route table, or one AZ's NAT becomes a shared dependency."
  }

  assert {
    condition = alltrue([
      for r in output.routing.default_routes : !contains(output.routing.db_route_table_ids, r.route_table_id)
    ])
    error_message = "DB subnets must have no default route (no internet, no NAT)."
  }

  assert {
    condition     = length(setintersection(toset(output.routing.db_route_table_ids), toset(concat(output.routing.public_route_table_ids, output.routing.app_route_table_ids)))) == 0
    error_message = "DB subnets must not share a route table with the public or app tiers."
  }

  assert {
    condition     = toset(output.db_security_posture.db_subnet_ids) == toset([for s in output.subnets.db : s.id])
    error_message = "The DB subnet group must contain the DB-tier subnets only."
  }

  assert {
    condition     = output.db_security_posture.vpc_security_group_ids == toset([output.db_security_posture.db_security_group_id])
    error_message = "The instance must use only its own security group."
  }

  assert {
    condition     = length(output.db_security_posture.ingress_rules) == 1
    error_message = "The DB security group must have exactly one ingress rule."
  }

  assert {
    condition = alltrue([
      for r in output.db_security_posture.ingress_rules :
      r.source_security_group_id == output.app_security_group_id && r.from_port == 5432 && r.to_port == 5432
      && r.cidr_ipv4 == null && r.cidr_ipv6 == null && r.prefix_list_id == null
    ])
    error_message = "DB ingress must be 5432 from sg-app only, with no CIDR or prefix-list source."
  }
}

# Dev trades AZ resilience for cost; this proves the trade-off is exactly the documented one and that the database
# is just as private as in prod. Mock provider: no AWS calls, no credentials (see envs/prod/tests/prod.tftest.hcl).

mock_provider "aws" {
  source = "../../tests/mocks"
}

run "layout_and_cost_trade_offs" {
  command = plan

  assert {
    condition     = output.azs == tolist(["ap-south-1a", "ap-south-1b"])
    error_message = "Dev spans two AZs."
  }

  assert {
    condition = (
      [for s in output.subnets.public : s.cidr] == ["10.10.0.0/24", "10.10.1.0/24"] &&
      [for s in output.subnets.app : s.cidr] == ["10.10.10.0/24", "10.10.11.0/24"] &&
      [for s in output.subnets.db : s.cidr] == ["10.10.20.0/24", "10.10.21.0/24"]
    )
    error_message = "Dev subnets must use 10.10.0.0/16 with the same offsets as prod (no overlap with prod's 10.0.0.0/16)."
  }

  assert {
    condition     = output.db_security_posture.multi_az == false && output.db_security_posture.deletion_protection == false
    error_message = "Dev runs a single-AZ database without deletion protection (cost, disposable env)."
  }

  assert {
    condition     = output.db_security_posture.backup_retention_period == 7
    error_message = "Dev keeps 7 days of backups."
  }

  assert {
    condition = (
      output.db_security_posture.publicly_accessible == false &&
      output.db_security_posture.storage_encrypted &&
      output.db_security_posture.manage_master_user_password &&
      output.db_security_posture.force_ssl == "1"
    )
    error_message = "Dev's database must be as private and encrypted as prod's."
  }
}

run "single_nat_and_private_db" {
  command = apply

  assert {
    condition     = length(output.nat_gateway_ids) == 1
    error_message = "Dev uses one shared NAT gateway."
  }

  assert {
    condition = alltrue([
      for rt in output.routing.app_route_table_ids :
      [for r in output.routing.default_routes : r.target if r.route_table_id == rt] == [output.nat_gateway_ids[0]]
    ])
    error_message = "Every dev app subnet must default-route to the single NAT gateway."
  }

  assert {
    condition = alltrue([
      for r in output.routing.default_routes : !contains(output.routing.db_route_table_ids, r.route_table_id)
    ])
    error_message = "DB subnets must have no default route."
  }

  assert {
    condition = alltrue([
      for r in output.db_security_posture.ingress_rules :
      r.source_security_group_id == output.app_security_group_id && r.from_port == 5432 && r.to_port == 5432
      && r.cidr_ipv4 == null && r.cidr_ipv6 == null && r.prefix_list_id == null
    ]) && length(output.db_security_posture.ingress_rules) == 1
    error_message = "DB ingress must be 5432 from sg-app only."
  }
}

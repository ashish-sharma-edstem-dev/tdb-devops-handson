# Prod: three AZs, a NAT gateway per AZ and a Multi-AZ database, so losing any one AZ keeps the service up.
locals {
  name   = "tdb-bookings-prod"
  region = "ap-south-1"

  vpc_cidr           = "10.0.0.0/16"
  azs                = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
  single_nat_gateway = false

  db = {
    engine_version        = "17"
    instance_class        = "db.m7g.large"
    allocated_storage     = 100
    max_allocated_storage = 500
    multi_az              = true
    backup_retention_days = 30
    deletion_protection   = true
  }
}

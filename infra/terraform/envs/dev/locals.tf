# Dev: two AZs, one NAT, single-AZ database. Cheap, and allowed to go down with an AZ.
locals {
  name   = "tdb-bookings-dev"
  region = "ap-south-1"

  vpc_cidr           = "10.10.0.0/16"
  azs                = ["ap-south-1a", "ap-south-1b"]
  single_nat_gateway = true

  db = {
    engine_version        = "17"
    instance_class        = "db.t4g.micro"
    allocated_storage     = 20
    max_allocated_storage = 50
    multi_az              = false
    backup_retention_days = 7
    deletion_protection   = false
  }
}

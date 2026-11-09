module "network" {
  source = "../../modules/network"

  name               = local.name
  cidr               = local.vpc_cidr
  azs                = local.azs
  single_nat_gateway = local.single_nat_gateway
}

module "postgres" {
  source = "../../modules/postgres"

  name                    = local.name
  vpc_id                  = module.network.vpc_id
  db_subnet_ids           = module.network.db_subnet_ids
  allowed_security_groups = { app = module.network.app_security_group_id }

  engine_version        = local.db.engine_version
  instance_class        = local.db.instance_class
  allocated_storage     = local.db.allocated_storage
  max_allocated_storage = local.db.max_allocated_storage
  multi_az              = local.db.multi_az
  backup_retention_days = local.db.backup_retention_days
  deletion_protection   = local.db.deletion_protection
}

# Input validations reject unsafe or off-design values at plan time, before anything reaches AWS.

mock_provider "aws" {
  source = "../../tests/mocks"
}

variables {
  name = "tdb-guard-test"
}

run "network_rejects_single_az" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    cidr = "10.0.0.0/16"
    azs  = ["ap-south-1a"]
  }

  expect_failures = [var.azs]
}

run "network_rejects_duplicate_azs" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    cidr = "10.0.0.0/16"
    azs  = ["ap-south-1a", "ap-south-1a", "ap-south-1b"]
  }

  expect_failures = [var.azs]
}

run "network_rejects_non_slash16" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    cidr = "10.0.0.0/20"
    azs  = ["ap-south-1a", "ap-south-1b"]
  }

  expect_failures = [var.cidr]
}

run "postgres_rejects_unsupported_major" {
  command = plan

  module {
    source = "../../modules/postgres"
  }

  variables {
    vpc_id                  = "vpc-0123456789abcdef0"
    db_subnet_ids           = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
    allowed_security_groups = { app = "sg-0123456789abcdef0" }
    instance_class          = "db.t4g.micro"
    engine_version          = "14"
  }

  expect_failures = [var.engine_version]
}

run "postgres_rejects_single_subnet" {
  command = plan

  module {
    source = "../../modules/postgres"
  }

  variables {
    vpc_id                  = "vpc-0123456789abcdef0"
    db_subnet_ids           = ["subnet-0aaaaaaaaaaaaaaaa"]
    allowed_security_groups = { app = "sg-0123456789abcdef0" }
    instance_class          = "db.t4g.micro"
  }

  expect_failures = [var.db_subnet_ids]
}

run "postgres_rejects_no_allowed_source" {
  command = plan

  module {
    source = "../../modules/postgres"
  }

  variables {
    vpc_id                  = "vpc-0123456789abcdef0"
    db_subnet_ids           = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
    allowed_security_groups = {}
    instance_class          = "db.t4g.micro"
  }

  expect_failures = [var.allowed_security_groups]
}

run "postgres_rejects_storage_ceiling_below_size" {
  command = plan

  module {
    source = "../../modules/postgres"
  }

  variables {
    vpc_id                  = "vpc-0123456789abcdef0"
    db_subnet_ids           = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
    allowed_security_groups = { app = "sg-0123456789abcdef0" }
    instance_class          = "db.t4g.micro"
    allocated_storage       = 100
    max_allocated_storage   = 100
  }

  expect_failures = [aws_db_instance.this]
}

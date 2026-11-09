terraform {
  # Bootstrap keeps its own state locally (terraform.tfstate, gitignored): the bucket that would hold remote
  # state is what this root creates. See ../README.md, "Bootstrapping the state bucket".
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

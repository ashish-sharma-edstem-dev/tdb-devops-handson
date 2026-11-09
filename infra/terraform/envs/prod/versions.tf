terraform {
  # 1.10 adds S3-native state locking (use_lockfile), so no DynamoDB lock table is needed.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

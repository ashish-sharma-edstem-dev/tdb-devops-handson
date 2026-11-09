provider "aws" {
  region = local.region

  # Refuse to run against any account other than the one this env belongs to, once it is set.
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Environment = "prod"
      Service     = "tdb-bookings"
      ManagedBy   = "terraform"
      Repository  = "github.com/ashish-sharma-edstem-dev/tdb-devops-handson"
    }
  }
}

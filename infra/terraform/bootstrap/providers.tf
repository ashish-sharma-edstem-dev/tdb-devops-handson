provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Service    = "tdb-bookings"
      Component  = "terraform-state"
      ManagedBy  = "terraform"
      Repository = "github.com/ashish-sharma-edstem-dev/tdb-devops-handson"
    }
  }
}

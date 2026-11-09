# The bucket name contains the AWS account ID, so it is passed at init time (partial configuration):
#   terraform init -backend-config="bucket=tdb-bookings-tfstate-<account id>"
# Everything else is fixed here so every engineer and CI job uses the same key, lock and encryption.
terraform {
  backend "s3" {
    key    = "tdb-bookings/dev/terraform.tfstate"
    region = "ap-south-1"

    # Without kms_key_id the backend sends SSE-S3 (AES256) explicitly, overriding the bucket's KMS default.
    # The alias resolves in the caller's account; the bucket policy rejects AES256 uploads.
    encrypt    = true
    kms_key_id = "alias/tdb-bookings-tfstate"

    # Native S3 lock: Terraform writes <key>.tflock with a conditional PUT (If-None-Match), so a second
    # plan/apply on the same env fails with "state locked" instead of racing.
    use_lockfile = true
  }
}

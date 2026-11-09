# Mock AWS provider for `terraform test`: no credentials, no API calls. Resources get generated IDs; only the data
# sources below need realistic values because the provider validates ARNs and policy JSON built from them.
mock_data "aws_partition" {
  defaults = {
    partition = "aws"
  }
}

mock_data "aws_caller_identity" {
  defaults = {
    account_id = "111122223333"
  }
}

mock_data "aws_region" {
  defaults = {
    region = "ap-south-1"
  }
}

mock_data "aws_iam_policy_document" {
  defaults = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

# Generated IDs are random strings; these resources' ARNs feed attributes the provider validates as ARNs.
mock_resource "aws_kms_key" {
  defaults = {
    arn = "arn:aws:kms:ap-south-1:111122223333:key/00000000-0000-0000-0000-000000000000"
  }
}

mock_resource "aws_iam_role" {
  defaults = {
    arn = "arn:aws:iam::111122223333:role/mock"
  }
}

mock_resource "aws_cloudwatch_log_group" {
  defaults = {
    arn = "arn:aws:logs:ap-south-1:111122223333:log-group:mock"
  }
}

# RDS fills master_user_secret when manage_master_user_password = true; the mock must too.
mock_resource "aws_db_instance" {
  defaults = {
    master_user_secret = [{
      secret_arn    = "arn:aws:secretsmanager:ap-south-1:111122223333:secret:rds!db-mock"
      secret_status = "active"
      kms_key_id    = "arn:aws:kms:ap-south-1:111122223333:key/00000000-0000-0000-0000-000000000000"
    }]
  }
}

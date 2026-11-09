output "bucket_name" {
  description = "Pass to each env as: terraform init -backend-config=\"bucket=<this>\"."
  value       = aws_s3_bucket.state.id
}

output "kms_key_arn" {
  description = "CMK that encrypts state objects and lock files."
  value       = aws_kms_key.state.arn
}

output "kms_alias" {
  description = "Alias the env backends use as kms_key_id."
  value       = aws_kms_alias.state.name
}

# Values printed after apply (and readable by scripts)
output "datalake_bucket" {
  description = "Name of the S3 data lake bucket"
  value       = aws_s3_bucket.datalake.bucket
}

output "glue_role_arn" {
  description = "ARN of the IAM role Glue uses"
  value       = aws_iam_role.glue.arn
}
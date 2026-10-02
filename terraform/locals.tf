# Look up the current AWS account (read-only)
data "aws_caller_identity" "current" {}

# Values computed once and reused everywhere
locals {
  # S3 bucket names are globally unique, so we add the account ID
  bucket_name = "${var.project_name}-datalake-${data.aws_caller_identity.current.account_id}"

  common_tags = {
    Project     = "marketplace-enrollment-data-platform"
    Environment = "lab"
    ManagedBy   = "terraform"
    DataClass   = "synthetic"
  }
}
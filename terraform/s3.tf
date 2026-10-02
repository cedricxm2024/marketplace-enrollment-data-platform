# ---------- S3 DATA LAKE ----------
resource "aws_s3_bucket" "datalake" {
  bucket        = local.bucket_name
  force_destroy = true # LAB ONLY: lets 'terraform destroy' delete a bucket that still has files
}

# Block ALL public access (nothing in this bucket is ever public)
resource "aws_s3_bucket_public_access_block" "datalake" {
  bucket                  = aws_s3_bucket.datalake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Encrypt every object at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "datalake" {
  bucket = aws_s3_bucket.datalake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Zone "folders" (S3 calls them prefixes) so the layout is visible in the console
resource "aws_s3_object" "zones" {
  for_each = toset([
    "raw/sqlserver/",
    "raw/postgres/",
    "curated/enrollment/",
    "curated/plans/",
    "rejected/",
    "athena-results/",
  ])

  bucket  = aws_s3_bucket.datalake.id
  key     = each.value
  content = ""
}
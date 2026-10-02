# ---------- AWS GLUE: script, ETL job, Data Catalog, crawler ----------

# Upload the ETL script to S3 (re-uploads automatically when the file changes)
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.datalake.id
  key    = "glue-scripts/marketplace_etl.py"
  source = "${path.module}/../glue/marketplace_etl.py"
  etag   = filemd5("${path.module}/../glue/marketplace_etl.py")
}

resource "aws_glue_job" "etl" {
  name              = "${var.project_name}-marketplace-etl"
  role_arn          = aws_iam_role.glue.arn # least-privilege role from iam.tf
  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = 2  # smallest practical size: keeps cost to cents
  timeout           = 15 # minutes: a runaway job can't burn money

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.datalake.bucket}/${aws_s3_object.glue_script.key}"
  }

  default_arguments = {
    "--DATALAKE_BUCKET"                  = aws_s3_bucket.datalake.bucket
    "--TempDir"                          = "s3://${aws_s3_bucket.datalake.bucket}/glue-temp/"
    "--enable-continuous-cloudwatch-log" = "true"
  }
}

# Data Catalog = METADATA (table names, columns, types). S3 holds the DATA.
resource "aws_glue_catalog_database" "lake" {
  name = "${var.project_name}_lake"
}

# Crawler = scans curated Parquet and records its schema in the catalog
resource "aws_glue_crawler" "curated" {
  name          = "${var.project_name}-curated-crawler"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.lake.name

  s3_target { path = "s3://${aws_s3_bucket.datalake.bucket}/curated/enrollment/" }
  s3_target { path = "s3://${aws_s3_bucket.datalake.bucket}/curated/plans/" }
  s3_target { path = "s3://${aws_s3_bucket.datalake.bucket}/curated/members/" }
}
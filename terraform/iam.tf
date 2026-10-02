# ---------- IAM ROLE FOR AWS GLUE (least privilege) ----------

# TRUST POLICY: only the AWS Glue service may assume this role
data "aws_iam_policy_document" "glue_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue" {
  name               = "${var.project_name}-glue-role"
  assume_role_policy = data.aws_iam_policy_document.glue_trust.json
}

# AWS-managed baseline for Glue (CloudWatch logs, Glue catalog access)
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# PERMISSIONS POLICY: exactly which parts of OUR bucket Glue may touch
data "aws_iam_policy_document" "glue_s3" {
  statement {
    sid       = "ListDataLake"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.datalake.arn]
  }

  statement {
    sid     = "ReadRawAndScripts"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.datalake.arn}/raw/*",
      "${aws_s3_bucket.datalake.arn}/glue-scripts/*",
    ]
  }

  statement {
    sid     = "WriteOutputs"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.datalake.arn}/curated/*",
      "${aws_s3_bucket.datalake.arn}/rejected/*",
      "${aws_s3_bucket.datalake.arn}/glue-temp/*",
    ]
  }
}

resource "aws_iam_role_policy" "glue_s3" {
  name   = "${var.project_name}-glue-s3-least-privilege"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue_s3.json
}
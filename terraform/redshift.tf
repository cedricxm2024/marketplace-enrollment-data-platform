# ---------- REDSHIFT SERVERLESS: analytical data warehouse (OLAP) ----------

variable "my_ip_cidr" {
  description = "Laptop public IP as x.x.x.x/32 (set via TF_VAR_my_ip_cidr; never committed)"
  type        = string
}

# Use the account's default VPC: no new networking, no NAT Gateway cost
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone-id" # skip use1-az3, which some services don't support
    values = ["use1-az1", "use1-az2", "use1-az4", "use1-az5", "use1-az6"]
  }
}

# Network access: Redshift port reachable ONLY from my laptop's IP (never 0.0.0.0/0)
resource "aws_security_group" "redshift" {
  name        = "${var.project_name}-redshift-sg"
  description = "Redshift access from my laptop IP only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Redshift 5439 from my IP only"
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Role Redshift uses to read the CURATED zone + Glue Data Catalog (read-only)
data "aws_iam_policy_document" "redshift_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["redshift.amazonaws.com", "redshift-serverless.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "redshift" {
  name               = "${var.project_name}-redshift-role"
  assume_role_policy = data.aws_iam_policy_document.redshift_trust.json
}

data "aws_iam_policy_document" "redshift_read_lake" {
  statement {
    sid       = "ListDataLake"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.datalake.arn]
  }

  statement {
    sid       = "ReadCuratedOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.datalake.arn}/curated/*"]
  }

  statement {
    sid = "ReadGlueCatalog"
    actions = [
      "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables",
      "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/default",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.lake.name}",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.lake.name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "redshift_read_lake" {
  name   = "${var.project_name}-redshift-read-curated"
  role   = aws_iam_role.redshift.id
  policy = data.aws_iam_policy_document.redshift_read_lake.json
}

# Namespace = the database + storage. Admin password is generated and kept in Secrets Manager.
resource "aws_redshiftserverless_namespace" "dw" {
  namespace_name        = "${var.project_name}-dw"
  db_name               = "marketplace"
  admin_username        = "dwadmin"
  manage_admin_password = true
  iam_roles             = [aws_iam_role.redshift.arn]
  default_iam_role_arn  = aws_iam_role.redshift.arn
}

# Workgroup = the compute. Smallest size, capped so it can't scale up.
resource "aws_redshiftserverless_workgroup" "dw" {
  namespace_name      = aws_redshiftserverless_namespace.dw.namespace_name
  workgroup_name      = "${var.project_name}-wg"
  base_capacity       = 8    # smallest practical RPU
  max_capacity        = 8    # cost guardrail
  publicly_accessible = true # internet-reachable ONLY through the security group above (my IP)
  subnet_ids          = data.aws_subnets.default.ids
  security_group_ids  = [aws_security_group.redshift.id]
}

output "redshift_endpoint" {
  value = aws_redshiftserverless_workgroup.dw.endpoint[0].address
}

output "redshift_admin_secret_arn" {
  value = aws_redshiftserverless_namespace.dw.admin_password_secret_arn
}

output "redshift_role_arn" {
  value = aws_iam_role.redshift.arn
}
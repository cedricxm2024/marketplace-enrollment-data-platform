"""
marketplace_etl.py  (AWS Glue 5.0 / PySpark)
RAW (CSV) -> standardize -> validate -> REJECTED (CSV + reasons) and CURATED (Parquet)

Data quality rules (first failing rule wins):
  MISSING_REQUIRED_FIELD, INVALID_MEMBER_ID, INVALID_PLAN_ID,
  NEGATIVE_PREMIUM, INVALID_STATUS, INVALID_DATE_RANGE, DUPLICATE_ENROLLMENT
"""
import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.window import Window

args = getResolvedOptions(sys.argv, ["JOB_NAME", "DATALAKE_BUCKET"])
glue_context = GlueContext(SparkContext())
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

LAKE = f"s3://{args['DATALAKE_BUCKET']}"
VALID_STATUSES = ["PENDING", "ACTIVE", "TERMINATED", "CANCELLED"]
ENR_COLS = ["enrollment_id", "member_id", "plan_id", "coverage_year",
            "effective_date", "termination_date", "status", "monthly_premium"]


def read_latest(path):
    """EXTRACT: read raw CSVs as plain text; keep only the newest batch file."""
    df = (spark.read.option("header", True).option("recursiveFileLookup", True)
          .csv(path).withColumn("source_file", F.input_file_name()))
    newest = df.agg(F.max("source_file")).first()[0]  # file names start with the batch timestamp
    return df.filter(F.col("source_file") == newest)


def blank_to_null(col_name):
    trimmed = F.trim(F.col(col_name))
    return F.when(trimmed == "", None).otherwise(trimmed)


def standardize(df, source_system):
    """TRANSFORM: apply the target schema (types) to raw text columns."""
    return (df.select(*ENR_COLS, "source_file")
            .withColumn("source_system", F.lit(source_system))
            .withColumn("enrollment_id", F.col("enrollment_id").cast("bigint"))
            .withColumn("member_id", F.col("member_id").cast("bigint"))
            .withColumn("plan_id", blank_to_null("plan_id"))
            .withColumn("coverage_year", F.col("coverage_year").cast("int"))
            .withColumn("effective_date", F.to_date("effective_date"))
            .withColumn("termination_date", F.to_date("termination_date"))
            .withColumn("status", F.upper(blank_to_null("status")))
            .withColumn("monthly_premium", F.col("monthly_premium").cast("decimal(10,2)")))


# ---------- EXTRACT ----------
members = read_latest(f"{LAKE}/raw/sqlserver/members/").select(
    F.col("member_id").cast("bigint").alias("member_id"),
    F.col("state_code").alias("member_state"),
    F.col("age_band").alias("age_band"),
    F.col("household_size").cast("int").alias("household_size"))
plans = read_latest(f"{LAKE}/raw/postgres/plans/").select(
    "plan_id", "issuer_id", "plan_name", "metal_level")
issuers = read_latest(f"{LAKE}/raw/postgres/issuers/").select(
    "issuer_id", "issuer_name", F.col("state_code").alias("issuer_state"))

incoming = (standardize(read_latest(f"{LAKE}/raw/sqlserver/enrollments/"), "sqlserver")
            .unionByName(standardize(read_latest(f"{LAKE}/raw/external/enrollment_feed/"),
                                     "external_feed")))

# ---------- VALIDATE ----------
member_keys = members.select(F.col("member_id").alias("known_member_id"))
plan_keys = plans.select(F.col("plan_id").alias("known_plan_id"))
dup_window = Window.partitionBy("enrollment_id").orderBy("source_system", "source_file")

checked = (incoming
    .join(member_keys, F.col("member_id") == F.col("known_member_id"), "left")
    .join(plan_keys, F.col("plan_id") == F.col("known_plan_id"), "left")
    .withColumn("dup_rank", F.row_number().over(dup_window))
    .withColumn("rejection_reason",
        F.when(F.col("enrollment_id").isNull() | F.col("member_id").isNull()
               | F.col("plan_id").isNull() | F.col("effective_date").isNull()
               | F.col("status").isNull() | F.col("monthly_premium").isNull(),
               "MISSING_REQUIRED_FIELD")
         .when(F.col("known_member_id").isNull(), "INVALID_MEMBER_ID")   # referential integrity
         .when(F.col("known_plan_id").isNull(), "INVALID_PLAN_ID")       # cross-system integrity
         .when(F.col("monthly_premium") < 0, "NEGATIVE_PREMIUM")
         .when(~F.col("status").isin(VALID_STATUSES), "INVALID_STATUS")
         .when(F.col("termination_date") < F.col("effective_date"), "INVALID_DATE_RANGE")
         .when(F.col("dup_rank") > 1, "DUPLICATE_ENROLLMENT"))          # uniqueness
    .withColumn("ingestion_timestamp", F.current_timestamp())
    .drop("known_member_id", "known_plan_id", "dup_rank")
    .cache())

rejected = checked.filter(F.col("rejection_reason").isNotNull())
accepted = checked.filter(F.col("rejection_reason").isNull()).drop("rejection_reason")

# ---------- RECONCILE (fail loudly; never hide a mismatch) ----------
extracted_n, accepted_n, rejected_n = checked.count(), accepted.count(), rejected.count()
by_reason = rejected.groupBy("rejection_reason").count()
print(f"RECONCILIATION extracted={extracted_n} accepted={accepted_n} rejected={rejected_n}")
print("REJECTIONS BY REASON", {r["rejection_reason"]: r["count"] for r in by_reason.collect()})
if extracted_n != accepted_n + rejected_n:
    raise RuntimeError("Reconciliation failed: extracted != accepted + rejected")

# ---------- INTEGRATE (plan/issuer from PostgreSQL + member from SQL Server) ----------
plan_dim = plans.join(issuers, "issuer_id", "left")
curated = (accepted
    .join(plan_dim.select("plan_id", "plan_name", "metal_level", "issuer_id", "issuer_name"),
          "plan_id", "left")
    .join(members.select("member_id", "member_state", "age_band"), "member_id", "left")
    .withColumn("active_indicator", F.col("status") == "ACTIVE"))

# ---------- LOAD ----------
# Tiny data -> coalesce(1) = one file per dataset (avoids the "small files" problem; no partitions needed)
(rejected.coalesce(1).write.mode("overwrite").option("header", True)
    .csv(f"{LAKE}/rejected/enrollment/"))
curated.coalesce(1).write.mode("overwrite").parquet(f"{LAKE}/curated/enrollment/")
plan_dim.coalesce(1).write.mode("overwrite").parquet(f"{LAKE}/curated/plans/")
members.coalesce(1).write.mode("overwrite").parquet(f"{LAKE}/curated/members/")
by_reason.coalesce(1).write.mode("overwrite").parquet(f"{LAKE}/curated/dq_rejections_by_reason/")
(spark.createDataFrame([(extracted_n, accepted_n, rejected_n,
                         round(accepted_n / extracted_n, 4))],
                       ["extracted", "accepted", "rejected", "pass_rate"])
    .coalesce(1).write.mode("overwrite").parquet(f"{LAKE}/curated/dq_summary/"))

job.commit()
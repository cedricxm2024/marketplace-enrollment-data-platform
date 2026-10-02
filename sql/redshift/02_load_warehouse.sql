/*
  02_load_warehouse.sql
  Set-based bulk loads (never row-by-row INSERTs).
  Dimensions first, then the fact (it needs the dimension surrogate keys).
*/

INSERT INTO dim_issuer (issuer_id, issuer_name, issuer_state)
SELECT DISTINCT issuer_id, issuer_name, issuer_state
FROM lake.plans;

INSERT INTO dim_plan (plan_id, plan_name, metal_level, issuer_id)
SELECT plan_id, plan_name, metal_level, issuer_id
FROM lake.plans;

INSERT INTO dim_member (member_id, state_code, age_band, household_size)
SELECT member_id, member_state, age_band, household_size
FROM lake.members;

INSERT INTO fact_enrollment (enrollment_id, member_key, plan_key, issuer_key, coverage_year,
                             effective_date, termination_date, status, monthly_premium,
                             enrollment_count, active_indicator, source_system)
SELECT e.enrollment_id, m.member_key, p.plan_key, i.issuer_key, e.coverage_year,
       e.effective_date, e.termination_date, e.status, e.monthly_premium,
       1, e.active_indicator, e.source_system
FROM lake.enrollment e
JOIN dim_member m ON m.member_id = e.member_id
JOIN dim_plan   p ON p.plan_id   = e.plan_id
JOIN dim_issuer i ON i.issuer_id = p.issuer_id;

-- COPY = Redshift's parallel bulk loader, reading Parquet straight from S3
COPY dq_summary
FROM 's3://{{BUCKET}}/curated/dq_summary/'
IAM_ROLE default
FORMAT AS PARQUET;

COPY dq_rejections_by_reason
FROM 's3://{{BUCKET}}/curated/dq_rejections_by_reason/'
IAM_ROLE default
FORMAT AS PARQUET;
/*
  01_create_star_schema.sql
  Star schema for Marketplace enrollment analytics (Redshift Serverless).
  GRAIN of fact_enrollment: one row = one enrollment for one member in one plan
  for its coverage period.
*/

-- Spectrum: lets Redshift read the curated Parquet in S3 through the Glue Data Catalog
CREATE EXTERNAL SCHEMA IF NOT EXISTS lake
FROM DATA CATALOG DATABASE 'mep_lake'
IAM_ROLE default;

DROP TABLE IF EXISTS fact_enrollment;
DROP TABLE IF EXISTS dim_member;
DROP TABLE IF EXISTS dim_plan;
DROP TABLE IF EXISTS dim_issuer;
DROP TABLE IF EXISTS dq_summary;
DROP TABLE IF EXISTS dq_rejections_by_reason;

-- DIMENSIONS: descriptive context ("who / what / where"). Small, copied to every node (DISTSTYLE ALL).
CREATE TABLE dim_issuer (
    issuer_key    INT IDENTITY(1,1) PRIMARY KEY,
    issuer_id     VARCHAR(5) NOT NULL,
    issuer_name   VARCHAR(100),
    issuer_state  CHAR(2)
) DISTSTYLE ALL;

CREATE TABLE dim_plan (
    plan_key      INT IDENTITY(1,1) PRIMARY KEY,
    plan_id       VARCHAR(20) NOT NULL,
    plan_name     VARCHAR(100),
    metal_level   VARCHAR(10),
    issuer_id     VARCHAR(5)
) DISTSTYLE ALL;

CREATE TABLE dim_member (
    member_key      INT IDENTITY(1,1) PRIMARY KEY,
    member_id       BIGINT NOT NULL,
    state_code      CHAR(2),
    age_band        VARCHAR(10),
    household_size  SMALLINT
) DISTSTYLE ALL;

-- FACT: measurable events at the declared grain. Surrogate keys point to dimensions.
CREATE TABLE fact_enrollment (
    enrollment_key    BIGINT IDENTITY(1,1),
    enrollment_id     BIGINT NOT NULL,
    member_key        INT REFERENCES dim_member(member_key),
    plan_key          INT REFERENCES dim_plan(plan_key),
    issuer_key        INT REFERENCES dim_issuer(issuer_key),
    coverage_year     SMALLINT,
    effective_date    DATE,
    termination_date  DATE,
    status            VARCHAR(20),
    monthly_premium   DECIMAL(10,2),
    enrollment_count  SMALLINT,
    active_indicator  BOOLEAN,
    source_system     VARCHAR(20)
)
DISTKEY (member_key)
SORTKEY (effective_date);

-- DATA QUALITY tables (for the dashboard's pass-rate KPI and failures chart)
CREATE TABLE dq_summary (
    extracted  BIGINT,
    accepted   BIGINT,
    rejected   BIGINT,
    pass_rate  DOUBLE PRECISION
);

CREATE TABLE dq_rejections_by_reason (
    rejection_reason  VARCHAR(40),
    rejected_count    BIGINT
);
/*
  02_create_schema.sql
  Operational (OLTP) schema for the Marketplace enrollment source system.
  Synthetic data only.
*/
USE MarketplaceEnrollment;
GO

-- 1. APPLICATIONS: one household's request for coverage in a given year
CREATE TABLE dbo.applications (
    application_id      BIGINT       NOT NULL CONSTRAINT pk_applications PRIMARY KEY,
    coverage_year       SMALLINT     NOT NULL,
    state_code          CHAR(2)      NOT NULL,
    application_status  VARCHAR(20)  NOT NULL,
    submitted_date      DATE         NOT NULL,
    created_at          DATETIME2(0) NOT NULL CONSTRAINT df_app_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(0) NOT NULL CONSTRAINT df_app_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_app_status CHECK (application_status IN ('SUBMITTED','IN_REVIEW','APPROVED','DENIED')),
    CONSTRAINT ck_app_year   CHECK (coverage_year BETWEEN 2024 AND 2030)
);
GO

-- 2. MEMBERS: each person on an application (no names = no PII)
CREATE TABLE dbo.members (
    member_id       BIGINT       NOT NULL CONSTRAINT pk_members PRIMARY KEY,
    application_id  BIGINT       NOT NULL CONSTRAINT fk_members_app
                                 REFERENCES dbo.applications(application_id),
    state_code      CHAR(2)      NOT NULL,
    age_band        VARCHAR(10)  NOT NULL,
    household_size  SMALLINT     NOT NULL,
    created_at      DATETIME2(0) NOT NULL CONSTRAINT df_mem_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(0) NOT NULL CONSTRAINT df_mem_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_mem_age  CHECK (age_band IN ('0-20','21-34','35-49','50-64','65+')),
    CONSTRAINT ck_mem_hh   CHECK (household_size BETWEEN 1 AND 10)
);
GO

-- 3. ELIGIBILITY: SYSTEM-VERSIONED TEMPORAL TABLE (keeps full history automatically)
CREATE TABLE dbo.eligibility (
    eligibility_id      BIGINT       NOT NULL CONSTRAINT pk_eligibility PRIMARY KEY,
    member_id           BIGINT       NOT NULL CONSTRAINT fk_elig_member
                                     REFERENCES dbo.members(member_id),
    eligibility_status  VARCHAR(20)  NOT NULL,
    effective_date      DATE         NOT NULL,
    income_band         VARCHAR(20)  NOT NULL,
    created_at          DATETIME2(0) NOT NULL CONSTRAINT df_elig_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(0) NOT NULL CONSTRAINT df_elig_updated DEFAULT SYSUTCDATETIME(),
    ValidFrom  DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    ValidTo    DATETIME2 GENERATED ALWAYS AS ROW END   NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo),
    CONSTRAINT ck_elig_status CHECK (eligibility_status IN ('PENDING','ELIGIBLE','INELIGIBLE'))
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.eligibility_history));
GO

-- 4. ENROLLMENTS: a member's coverage in one plan (CDC will track this table)
CREATE TABLE dbo.enrollments (
    enrollment_id     BIGINT        NOT NULL CONSTRAINT pk_enrollments PRIMARY KEY,
    member_id         BIGINT        NOT NULL CONSTRAINT fk_enr_member
                                    REFERENCES dbo.members(member_id),
    plan_id           VARCHAR(20)   NOT NULL,  -- lives in PostgreSQL: no FK possible across systems
    coverage_year     SMALLINT      NOT NULL,
    effective_date    DATE          NOT NULL,
    termination_date  DATE          NULL,
    status            VARCHAR(20)   NOT NULL,
    monthly_premium   DECIMAL(10,2) NOT NULL,
    created_at        DATETIME2(0)  NOT NULL CONSTRAINT df_enr_created DEFAULT SYSUTCDATETIME(),
    updated_at        DATETIME2(0)  NOT NULL CONSTRAINT df_enr_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_enr_status  CHECK (status IN ('PENDING','ACTIVE','TERMINATED','CANCELLED')),
    CONSTRAINT ck_enr_premium CHECK (monthly_premium >= 0),
    CONSTRAINT ck_enr_dates   CHECK (termination_date IS NULL OR termination_date >= effective_date)
);
GO

-- Verify: 5 tables (eligibility_history is created automatically)
SELECT name, temporal_type_desc
FROM sys.tables
ORDER BY name;
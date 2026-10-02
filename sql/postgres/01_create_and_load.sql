/*
  01_create_and_load.sql
  Plan / issuer reference system (PostgreSQL). Synthetic data only.
  Creates tables, then bulk-loads the CSVs produced by generate_data.py.
*/

CREATE TABLE IF NOT EXISTS issuers (
    issuer_id    VARCHAR(5)    PRIMARY KEY,
    issuer_name  VARCHAR(100)  NOT NULL,
    state_code   CHAR(2)       NOT NULL,
    active_flag  BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS plans (
    plan_id        VARCHAR(20)   PRIMARY KEY,
    issuer_id      VARCHAR(5)    NOT NULL REFERENCES issuers(issuer_id),
    plan_name      VARCHAR(100)  NOT NULL,
    metal_level    VARCHAR(10)   NOT NULL
                   CHECK (metal_level IN ('Bronze','Silver','Gold','Platinum')),
    coverage_year  SMALLINT      NOT NULL,
    active_flag    BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS plan_rates (
    rate_id        INTEGER        PRIMARY KEY,
    plan_id        VARCHAR(20)    NOT NULL REFERENCES plans(plan_id),
    age_band       VARCHAR(10)    NOT NULL,
    monthly_rate   NUMERIC(10,2)  NOT NULL CHECK (monthly_rate >= 0),
    coverage_year  SMALLINT       NOT NULL,
    UNIQUE (plan_id, age_band, coverage_year)
);

CREATE TABLE IF NOT EXISTS service_areas (
    service_area_id  INTEGER      PRIMARY KEY,
    plan_id          VARCHAR(20)  NOT NULL REFERENCES plans(plan_id),
    state_code       CHAR(2)      NOT NULL,
    county_code      CHAR(3)      NOT NULL
);

-- Re-runnable: clear, then bulk load (parents before children)
TRUNCATE service_areas, plan_rates, plans, issuers;

COPY issuers       FROM '/data/sample/issuers.csv'       WITH (FORMAT csv, HEADER true);
COPY plans         FROM '/data/sample/plans.csv'         WITH (FORMAT csv, HEADER true);
COPY plan_rates    FROM '/data/sample/plan_rates.csv'    WITH (FORMAT csv, HEADER true);
COPY service_areas FROM '/data/sample/service_areas.csv' WITH (FORMAT csv, HEADER true);

-- Verify (should be 4 / 8 / 40 / 16)
SELECT 'issuers' AS table_name, COUNT(*) FROM issuers
UNION ALL SELECT 'plans',         COUNT(*) FROM plans
UNION ALL SELECT 'plan_rates',    COUNT(*) FROM plan_rates
UNION ALL SELECT 'service_areas', COUNT(*) FROM service_areas;

-- Integration preview: plans with their issuer
SELECT p.plan_id, p.plan_name, p.metal_level, i.issuer_name, i.state_code
FROM plans p
JOIN issuers i ON i.issuer_id = p.issuer_id
ORDER BY i.state_code, p.metal_level;
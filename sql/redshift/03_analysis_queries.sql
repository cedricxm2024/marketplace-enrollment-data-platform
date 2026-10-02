/*
  03_analysis_queries.sql
  Reconciliation + OLAP questions against the star schema.
*/

-- Reconciliation: fact rows must equal Glue accepted rows (3101)
SELECT 'dim_issuer' AS table_name, COUNT(*) AS row_count FROM dim_issuer
UNION ALL SELECT 'dim_plan', COUNT(*) FROM dim_plan
UNION ALL SELECT 'dim_member', COUNT(*) FROM dim_member
UNION ALL SELECT 'fact_enrollment', COUNT(*) FROM fact_enrollment
UNION ALL SELECT 'glue_accepted', accepted FROM dq_summary;

-- Enrollment and average premium by metal level
SELECT p.metal_level,
       SUM(f.enrollment_count) AS enrollments,
       ROUND(AVG(f.monthly_premium), 2) AS avg_monthly_premium
FROM fact_enrollment f
JOIN dim_plan p ON p.plan_key = f.plan_key
GROUP BY p.metal_level
ORDER BY enrollments DESC;

-- Data quality
SELECT * FROM dq_summary;
SELECT * FROM dq_rejections_by_reason ORDER BY rejected_count DESC;
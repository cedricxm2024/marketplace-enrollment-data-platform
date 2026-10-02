/*
  06_analysis_queries.sql
  T-SQL practice against the operational enrollment data.
  Run ONE query at a time: highlight it, then press F5.
*/
USE MarketplaceEnrollment;
GO

-- Q1. INNER JOIN + WHERE + ORDER BY
-- Business question: Which active enrollments have the highest premiums?
SELECT TOP 10
       e.enrollment_id, m.member_id, m.state_code, m.age_band,
       e.plan_id, e.monthly_premium
FROM dbo.enrollments AS e
INNER JOIN dbo.members AS m ON m.member_id = e.member_id
WHERE e.status = 'ACTIVE'
ORDER BY e.monthly_premium DESC;

-- Q2. LEFT JOIN
-- Business question: How many members have NO enrollment, and why?
SELECT el.eligibility_status, COUNT(*) AS members_without_enrollment
FROM dbo.members AS m
LEFT JOIN dbo.enrollments AS e  ON e.member_id = m.member_id
INNER JOIN dbo.eligibility AS el ON el.member_id = m.member_id
WHERE e.enrollment_id IS NULL
GROUP BY el.eligibility_status;

-- Q3. GROUP BY + HAVING
-- Business question: Average premium by state, only states with 300+ active enrollments
SELECT m.state_code,
       COUNT(*)               AS active_enrollments,
       AVG(e.monthly_premium) AS avg_monthly_premium
FROM dbo.enrollments AS e
INNER JOIN dbo.members AS m ON m.member_id = e.member_id
WHERE e.status = 'ACTIVE'          -- filters ROWS before grouping
GROUP BY m.state_code
HAVING COUNT(*) >= 300             -- filters GROUPS after grouping
ORDER BY avg_monthly_premium DESC;

-- Q4. CASE
-- Business question: How are active enrollments spread across premium tiers?
SELECT CASE
         WHEN monthly_premium < 400 THEN '1. Under $400'
         WHEN monthly_premium < 700 THEN '2. $400-$699'
         ELSE                            '3. $700+'
       END AS premium_tier,
       COUNT(*) AS enrollments
FROM dbo.enrollments
WHERE status = 'ACTIVE'
GROUP BY CASE
         WHEN monthly_premium < 400 THEN '1. Under $400'
         WHEN monthly_premium < 700 THEN '2. $400-$699'
         ELSE                            '3. $700+'
       END
ORDER BY premium_tier;

-- Q5. CTE (Common Table Expression)
-- Business question: How many members switched plans mid-year?
WITH enrollment_counts AS (
    SELECT member_id, COUNT(*) AS enrollment_count
    FROM dbo.enrollments
    GROUP BY member_id
)
SELECT enrollment_count, COUNT(*) AS members
FROM enrollment_counts
GROUP BY enrollment_count
ORDER BY enrollment_count;

-- Q6. TRANSACTION + ROLLBACK
-- Safely test a termination, then undo it. (Highlight from DECLARE to the end, F5.)
DECLARE @id BIGINT = (SELECT MIN(enrollment_id) FROM dbo.enrollments WHERE status = 'ACTIVE');

BEGIN TRANSACTION;
    UPDATE dbo.enrollments
    SET status = 'TERMINATED',
        termination_date = EOMONTH(effective_date, 2),
        updated_at = SYSUTCDATETIME()
    WHERE enrollment_id = @id;

    SELECT 'inside transaction' AS stage, enrollment_id, status, termination_date
    FROM dbo.enrollments WHERE enrollment_id = @id;
ROLLBACK TRANSACTION;

SELECT 'after rollback' AS stage, enrollment_id, status, termination_date
FROM dbo.enrollments WHERE enrollment_id = @id;
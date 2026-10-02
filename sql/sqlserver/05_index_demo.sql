/*
  05_index_demo.sql
  Execution plan before/after a nonclustered index on dbo.enrollments.
  Run PART A, review plan + reads. Then run PART B, compare.
*/

-- ===================== PART A: BEFORE the index =====================
USE MarketplaceEnrollment;
DROP INDEX IF EXISTS ix_enrollments_member_status ON dbo.enrollments;
SET STATISTICS IO ON;

DECLARE @member BIGINT = (SELECT MIN(member_id) FROM dbo.enrollments WHERE status = 'ACTIVE');

SELECT enrollment_id, plan_id, status, effective_date, monthly_premium
FROM dbo.enrollments
WHERE member_id = @member
  AND status = 'ACTIVE';
GO

-- ===================== PART B: AFTER the index =====================
USE MarketplaceEnrollment;
CREATE NONCLUSTERED INDEX ix_enrollments_member_status
    ON dbo.enrollments (member_id, status)
    INCLUDE (plan_id, effective_date, monthly_premium);
SET STATISTICS IO ON;

DECLARE @member BIGINT = (SELECT MIN(member_id) FROM dbo.enrollments WHERE status = 'ACTIVE');

SELECT enrollment_id, plan_id, status, effective_date, monthly_premium
FROM dbo.enrollments
WHERE member_id = @member
  AND status = 'ACTIVE';
GO
/*
  03b_cdc_change_demo.sql
  Generates INSERT / UPDATE / DELETE activity on dbo.enrollments,
  then reads the changes CDC captured from the transaction log.
*/
USE MarketplaceEnrollment;
GO

DECLARE @new_member BIGINT, @term_id BIGINT;

-- A TX member who has no enrollment yet (newly eligible)
SELECT TOP 1 @new_member = m.member_id
FROM dbo.members AS m
WHERE m.state_code = 'TX'
  AND NOT EXISTS (SELECT 1 FROM dbo.enrollments e WHERE e.member_id = m.member_id)
ORDER BY m.member_id;

-- An existing ACTIVE enrollment that will terminate
SELECT @term_id = MIN(enrollment_id) FROM dbo.enrollments WHERE status = 'ACTIVE';

IF NOT EXISTS (SELECT 1 FROM dbo.enrollments WHERE enrollment_id = 999001)  -- run-once guard
BEGIN
    -- 1. INSERT: new special-enrollment record
    INSERT INTO dbo.enrollments (enrollment_id, member_id, plan_id, coverage_year,
                                 effective_date, termination_date, status, monthly_premium)
    VALUES (999001, @new_member, '10001TX0010001', 2026, '2026-10-01', NULL, 'PENDING', 412.50);

    -- 2. INSERT: duplicate entered by mistake
    INSERT INTO dbo.enrollments (enrollment_id, member_id, plan_id, coverage_year,
                                 effective_date, termination_date, status, monthly_premium)
    VALUES (999002, @new_member, '10001TX0010001', 2026, '2026-10-01', NULL, 'PENDING', 412.50);

    -- 3. UPDATE: first premium paid -> coverage becomes ACTIVE
    UPDATE dbo.enrollments
    SET status = 'ACTIVE', updated_at = SYSUTCDATETIME()
    WHERE enrollment_id = 999001;

    -- 4. UPDATE: existing member terminates coverage
    UPDATE dbo.enrollments
    SET status = 'TERMINATED', termination_date = '2026-10-31', updated_at = SYSUTCDATETIME()
    WHERE enrollment_id = @term_id;

    -- 5. DELETE: remove the mistaken duplicate
    DELETE FROM dbo.enrollments WHERE enrollment_id = 999002;
END;

-- Give the CDC capture job time to read the transaction log (it polls every ~5 seconds)
WAITFOR DELAY '00:00:10';

-- LSN range = "from the oldest captured change to the newest"
DECLARE @from_lsn BINARY(10) = sys.fn_cdc_get_min_lsn('dbo_enrollments');
DECLARE @to_lsn   BINARY(10) = sys.fn_cdc_get_max_lsn();

-- A. ALL changes: every operation, including before AND after images of updates
SELECT sys.fn_cdc_map_lsn_to_time(__$start_lsn) AS change_time,
       __$start_lsn AS lsn,
       CASE __$operation
            WHEN 1 THEN 'DELETE'
            WHEN 2 THEN 'INSERT'
            WHEN 3 THEN 'UPDATE (before)'
            WHEN 4 THEN 'UPDATE (after)'
       END AS operation,
       enrollment_id, member_id, status, termination_date, monthly_premium
FROM cdc.fn_cdc_get_all_changes_dbo_enrollments(@from_lsn, @to_lsn, N'all update old')
ORDER BY __$start_lsn, __$seqval;

-- B. NET changes: only the final result per row over the same range
SELECT CASE __$operation WHEN 1 THEN 'DELETE' WHEN 2 THEN 'INSERT' WHEN 4 THEN 'UPDATE' END AS net_operation,
       enrollment_id, member_id, status, termination_date
FROM cdc.fn_cdc_get_net_changes_dbo_enrollments(@from_lsn, @to_lsn, N'all')
ORDER BY enrollment_id;
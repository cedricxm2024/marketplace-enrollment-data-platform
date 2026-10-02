/*
  03_enable_cdc.sql
  Enables SQL Server Change Data Capture (CDC) on dbo.enrollments.
  Requires SQL Server Agent to be running (it runs the capture + cleanup jobs).
*/
USE MarketplaceEnrollment;
GO

-- 1. Enable CDC at the database level (safe to re-run)
IF (SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()) = 0
    EXEC sys.sp_cdc_enable_db;
GO

-- 2. Enable CDC on the enrollments table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'enrollments' AND is_tracked_by_cdc = 1)
    EXEC sys.sp_cdc_enable_table
         @source_schema        = N'dbo',
         @source_name          = N'enrollments',
         @role_name            = NULL,  -- lab only; production would restrict reads to a role
         @supports_net_changes = 1;     -- allows "net" queries (final state per row)
GO

-- 3. Verify: database and table flags
SELECT name, is_cdc_enabled    FROM sys.databases WHERE name = DB_NAME();
SELECT name, is_tracked_by_cdc FROM sys.tables    WHERE name = 'enrollments';

-- 4. Verify: capture instance details
EXEC sys.sp_cdc_help_change_data_capture;

-- 5. Verify: the capture and cleanup jobs exist
EXEC sys.sp_cdc_help_jobs;
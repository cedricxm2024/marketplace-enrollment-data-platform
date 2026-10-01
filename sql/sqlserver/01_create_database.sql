/*
  01_create_database.sql
  Creates the operational enrollment database (OLTP source system).
  All data in this project is synthetic.
*/

IF DB_ID('MarketplaceEnrollment') IS NULL
    CREATE DATABASE MarketplaceEnrollment;
GO

SELECT name, create_date, recovery_model_desc
FROM sys.databases
WHERE name = 'MarketplaceEnrollment';
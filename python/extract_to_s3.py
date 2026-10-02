"""
extract_to_s3.py
Batch extraction to the S3 RAW zone (CSV, unmodified source data).

  1. SQL Server full load (enrollment system of record) -> raw/sqlserver/<table>/
  2. SQL Server CDC change extract (enrollments)        -> raw/sqlserver/enrollments_cdc/
  3. PostgreSQL full load (plan reference system)       -> raw/postgres/<table>/
  4. Simulated external enrollment feed with 75 intentionally invalid rows
                                                        -> raw/external/enrollment_feed/
  5. Manifest with row counts per file (lineage + reconciliation)
                                                        -> raw/_manifests/

Run from the project root:  python python/extract_to_s3.py
Needs env var DATALAKE_BUCKET and the .env file (POSTGRES_USER / POSTGRES_PASSWORD).
"""
import csv
import io
import json
import os
import random
from datetime import date, datetime, timezone
from pathlib import Path

import boto3
import psycopg2
import pyodbc

BUCKET = os.environ.get("DATALAKE_BUCKET")
RUN_TS = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")  # batch identifier
CHECKPOINT_FILE = Path("data/extracts/cdc_last_lsn.txt")         # gitignored

SQLSERVER_CONN = (
    "DRIVER={ODBC Driver 18 for SQL Server};SERVER=localhost;"
    "DATABASE=MarketplaceEnrollment;Trusted_Connection=yes;TrustServerCertificate=yes;"
)
SQLSERVER_TABLES = ["applications", "members", "eligibility", "enrollments"]
POSTGRES_TABLES = ["issuers", "plans", "plan_rates", "service_areas"]
FEED_COLUMNS = ["enrollment_id", "member_id", "plan_id", "coverage_year",
                "effective_date", "termination_date", "status", "monthly_premium"]


def read_env_file(path=".env"):
    """Minimal .env reader so the PostgreSQL password never appears in code."""
    values = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.strip().startswith("#"):
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def query(cursor, sql):
    cursor.execute(sql)
    columns = [c[0] for c in cursor.description]
    return columns, [tuple(r) for r in cursor.fetchall()]


def to_csv_bytes(columns, rows):
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(columns)
    writer.writerows(rows)
    return buf.getvalue().encode("utf-8")


def upload(s3, manifest, source, table, columns, rows):
    key = f"raw/{source}/{table}/{RUN_TS}_{table}.csv"
    s3.put_object(Bucket=BUCKET, Key=key, Body=to_csv_bytes(columns, rows))  # bucket encrypts at rest
    manifest.append({"source": source, "table": table, "s3_key": key, "row_count": len(rows)})
    print(f"  {len(rows):>5} rows -> s3://{BUCKET}/{key}")


def extract_sqlserver(s3, manifest):
    print("SQL Server (full load):")
    conn = pyodbc.connect(SQLSERVER_CONN)
    cur = conn.cursor()
    for table in SQLSERVER_TABLES:
        cols, rows = query(cur, f"SELECT * FROM dbo.{table}")
        upload(s3, manifest, "sqlserver", table, cols, rows)

    print("SQL Server CDC (changes read from the transaction log):")
    cols, rows = query(cur, """
        SET NOCOUNT ON;
        DECLARE @from BINARY(10) = sys.fn_cdc_get_min_lsn('dbo_enrollments');
        DECLARE @to   BINARY(10) = sys.fn_cdc_get_max_lsn();
        SELECT CONVERT(VARCHAR(22), __$start_lsn, 1) AS lsn,
               CASE __$operation WHEN 1 THEN 'DELETE' WHEN 2 THEN 'INSERT'
                                 WHEN 4 THEN 'UPDATE' END AS operation,
               enrollment_id, member_id, plan_id, status,
               effective_date, termination_date, monthly_premium
        FROM cdc.fn_cdc_get_all_changes_dbo_enrollments(@from, @to, N'all')
        ORDER BY __$start_lsn, __$seqval;
    """)
    upload(s3, manifest, "sqlserver", "enrollments_cdc", cols, rows)
    if rows:
        CHECKPOINT_FILE.parent.mkdir(parents=True, exist_ok=True)
        CHECKPOINT_FILE.write_text(rows[-1][0])  # next incremental run starts after this LSN
        print(f"  checkpoint saved: last processed LSN = {rows[-1][0]}")

    member_ids = [r[0] for r in query(cur, "SELECT member_id FROM dbo.members")[1]]
    conn.close()
    return member_ids


def extract_postgres(s3, manifest, env):
    print("PostgreSQL (full load):")
    conn = psycopg2.connect(host="127.0.0.1", port=5432, dbname="plan_reference",
                            user=env["POSTGRES_USER"], password=env["POSTGRES_PASSWORD"])
    cur = conn.cursor()
    for table in POSTGRES_TABLES:
        cols, rows = query(cur, f"SELECT * FROM {table}")
        upload(s3, manifest, "postgres", table, cols, rows)
    plan_ids = [r[0] for r in query(cur, "SELECT plan_id FROM plans")[1]]
    conn.close()
    return plan_ids


def build_external_feed(member_ids, plan_ids):
    """Partner feed: 100 valid rows + 75 intentionally invalid rows (~2.4% of all incoming)."""
    rng = random.Random(7)

    def row(enr_id, member=None, plan=None, term="", status="PENDING", premium=None):
        return [enr_id,
                member if member is not None else rng.choice(member_ids),
                plan if plan is not None else rng.choice(plan_ids),
                2026, "2026-11-01", term, status,
                premium if premium is not None else f"{rng.uniform(250, 900):.2f}"]

    valid = [row(950001 + i) for i in range(100)]
    bad, next_id = [], 950101

    def add(count, **kwargs):
        nonlocal next_id
        for _ in range(count):
            bad.append(row(next_id, **kwargs))
            next_id += 1

    add(10, member=999999)              # INVALID_MEMBER_ID   (member doesn't exist)
    add(10, plan="99999ZZ0010001")      # INVALID_PLAN_ID     (plan doesn't exist)
    add(10, premium="-150.00")          # NEGATIVE_PREMIUM
    add(10, status="ENROLLED")          # INVALID_STATUS      (not an allowed value)
    add(10, term="2026-10-15")          # INVALID_DATE_RANGE  (ends before Nov 1 start)
    add(15, plan="")                    # MISSING_REQUIRED_FIELD
    bad += [list(r) for r in valid[:10]]  # DUPLICATE_ENROLLMENT (same enrollment_id twice)
    return valid + bad


def main():
    if not BUCKET:
        raise SystemExit("Set DATALAKE_BUCKET first.")
    env = read_env_file()
    s3 = boto3.client("s3")
    manifest = []

    member_ids = extract_sqlserver(s3, manifest)
    plan_ids = extract_postgres(s3, manifest, env)

    print("External enrollment feed (contains intentional bad records):")
    upload(s3, manifest, "external", "enrollment_feed", FEED_COLUMNS,
           build_external_feed(member_ids, plan_ids))

    key = f"raw/_manifests/{RUN_TS}_manifest.json"
    body = json.dumps({"run_ts": RUN_TS, "files": manifest}, indent=2).encode("utf-8")
    s3.put_object(Bucket=BUCKET, Key=key, Body=body)
    total = sum(f["row_count"] for f in manifest)
    print(f"Manifest -> s3://{BUCKET}/{key}  ({len(manifest)} files, {total} rows)")


if __name__ == "__main__":
    main()
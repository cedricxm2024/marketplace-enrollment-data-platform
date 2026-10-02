"""
run_redshift_sql.py
Runs sql/redshift/*.sql files against Redshift Serverless.
The admin password is fetched from AWS Secrets Manager at runtime: never typed, never stored.
Usage (project root): python python/run_redshift_sql.py sql/redshift/01_create_star_schema.sql ...
"""
import json
import subprocess
import sys
from pathlib import Path

import boto3
import psycopg2


def terraform_outputs():
    result = subprocess.run(["terraform", "-chdir=terraform", "output", "-json"],
                            capture_output=True, text=True, check=True)
    return {k: v["value"] for k, v in json.loads(result.stdout).items()}


def statements(path, bucket):
    text = Path(path).read_text(encoding="utf-8").replace("{{BUCKET}}", bucket)
    text = "\n".join(line for line in text.splitlines() if not line.strip().startswith("--"))
    return [s.strip() for s in text.split(";") if s.strip()]


def main(files):
    tf = terraform_outputs()
    secret = json.loads(boto3.client("secretsmanager")
                        .get_secret_value(SecretId=tf["redshift_admin_secret_arn"])["SecretString"])
    conn = psycopg2.connect(host=tf["redshift_endpoint"], port=5439, dbname="marketplace",
                            user=secret["username"], password=secret["password"],
                            sslmode="require")  # encryption in transit
    conn.autocommit = True
    cur = conn.cursor()
    for path in files:
        print(f"===== {path}")
        for stmt in statements(path, tf["datalake_bucket"]):
            cur.execute(stmt)
            if cur.description:  # the statement returned rows
                print(" | ".join(d[0] for d in cur.description))
                for row in cur.fetchall():
                    print(" | ".join(str(v) for v in row))
                print()
    conn.close()
    print("Done.")


if __name__ == "__main__":
    main(sys.argv[1:])
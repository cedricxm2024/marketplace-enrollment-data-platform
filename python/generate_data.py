"""
generate_data.py
Generates SYNTHETIC Marketplace data (no real people, no PII).
  1. Plan/issuer reference data -> CSV in data/sample/ (for PostgreSQL)
  2. Applications, members, eligibility, enrollments -> SQL Server
Fixed random seed: every run produces the same data (reproducible).
"""
import csv
import random
from datetime import date, timedelta
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

import pyodbc

random.seed(42)

COVERAGE_YEAR = 2026
TARGET_MEMBERS = 2000
TARGET_ENROLLMENTS = 3000
OUT_DIR = Path("data/sample")
CENT = Decimal("0.01")

SQLSERVER_CONN = (
    "DRIVER={ODBC Driver 18 for SQL Server};"
    "SERVER=localhost;"
    "DATABASE=MarketplaceEnrollment;"
    "Trusted_Connection=yes;"       # Windows Authentication: no password in code
    "TrustServerCertificate=yes;"   # local lab uses a self-signed certificate
)

# ---------------- Reference data (owned by the PostgreSQL plan system) ----------------
ISSUERS = [  # issuer_id, fictional issuer_name, state_code
    ("10001", "Harbor Point Health", "TX"),
    ("10002", "Cedar Valley Health", "FL"),
    ("10003", "Summit Ridge Health", "GA"),
    ("10004", "Riverbend Health", "NC"),
]
PLAN_METALS = {
    "10001": ["Bronze", "Silver"],
    "10002": ["Silver", "Gold"],
    "10003": ["Bronze", "Gold"],
    "10004": ["Silver", "Platinum"],
}
BASE_RATE = {"Bronze": Decimal("380.00"), "Silver": Decimal("470.00"),
             "Gold": Decimal("560.00"), "Platinum": Decimal("660.00")}
AGE_FACTOR = {"0-20": Decimal("0.65"), "21-34": Decimal("0.90"),
              "35-49": Decimal("1.15"), "50-64": Decimal("1.75"), "65+": Decimal("2.00")}
ISSUER_FACTOR = [Decimal("1.00"), Decimal("1.04"), Decimal("0.97"), Decimal("1.08")]
COUNTY_CODES = ["001", "003", "005", "007"]
INCOME_BANDS = ["Under 138% FPL", "138-250% FPL", "250-400% FPL", "Over 400% FPL"]


def build_reference_data():
    issuers, plans, rates, service_areas = [], [], [], []
    rate_id = sa_id = 0
    for idx, (issuer_id, issuer_name, state) in enumerate(ISSUERS):
        issuers.append((issuer_id, issuer_name, state, True))
        short_name = issuer_name.rsplit(" ", 1)[0]
        for n, metal in enumerate(PLAN_METALS[issuer_id], start=1):
            plan_id = f"{issuer_id}{state}{n:03d}0001"   # e.g. 10001TX0010001
            network = "HMO" if n == 1 else "PPO"
            plans.append((plan_id, issuer_id, f"{short_name} {metal} {network}",
                          metal, COVERAGE_YEAR, True))
            for age_band, factor in AGE_FACTOR.items():
                rate_id += 1
                rate = (BASE_RATE[metal] * factor * ISSUER_FACTOR[idx]).quantize(CENT, ROUND_HALF_UP)
                rates.append((rate_id, plan_id, age_band, rate, COVERAGE_YEAR))
            for county in random.sample(COUNTY_CODES, 2):
                sa_id += 1
                service_areas.append((sa_id, plan_id, state, county))
    return issuers, plans, rates, service_areas


# ---------------- Operational data (owned by the SQL Server enrollment system) ----------------
def build_source_data(plans_by_state, rate_lookup):
    applications, members, eligibility, enrollments = [], [], [], []
    app_id, member_id, elig_id, enr_id = 500000, 100000, 700000, 900000
    states = list(plans_by_state)

    while len(members) < TARGET_MEMBERS:
        app_id += 1
        state = random.choice(states)
        household = min(random.choice([1, 1, 2, 2, 3, 4]), TARGET_MEMBERS - len(members))
        submitted = date(2025, 11, 1) + timedelta(days=random.randint(0, 75))  # open enrollment
        app_status = random.choices(["APPROVED", "IN_REVIEW", "SUBMITTED", "DENIED"],
                                    weights=[88, 5, 4, 3])[0]
        applications.append((app_id, COVERAGE_YEAR, state, app_status, submitted))

        elig_status = {"APPROVED": "ELIGIBLE", "DENIED": "INELIGIBLE"}.get(app_status, "PENDING")
        for _ in range(household):
            member_id += 1
            age_band = random.choices(list(AGE_FACTOR), weights=[20, 25, 25, 27, 3])[0]
            members.append((member_id, app_id, state, age_band, household))
            elig_id += 1
            eligibility.append((elig_id, member_id, elig_status,
                                date(COVERAGE_YEAR, 1, 1), random.choice(INCOME_BANDS)))

    # Only ELIGIBLE members enroll. Some switch plans mid-year -> 2 enrollment rows.
    eligible = [m for m, e in zip(members, eligibility) if e[2] == "ELIGIBLE"]
    switch_count = TARGET_ENROLLMENTS - len(eligible)
    assert 0 <= switch_count <= len(eligible), "Adjust weights: can't hit enrollment target"
    switchers = set(random.sample([m[0] for m in eligible], switch_count))

    for m_id, _, state, age_band, _ in eligible:
        state_plans = plans_by_state[state]
        if m_id in switchers:
            first, second = random.sample(state_plans, 2)
            month = random.randint(3, 9)
            switch_date = date(COVERAGE_YEAR, month, 1)
            enr_id += 1
            enrollments.append((enr_id, m_id, first, COVERAGE_YEAR, date(COVERAGE_YEAR, 1, 1),
                                switch_date - timedelta(days=1), "TERMINATED",
                                rate_lookup[(first, age_band)]))
            enr_id += 1
            enrollments.append((enr_id, m_id, second, COVERAGE_YEAR, switch_date, None,
                                "ACTIVE", rate_lookup[(second, age_band)]))
        else:
            plan = random.choice(state_plans)
            month = 1 if random.random() < 0.8 else random.randint(2, 9)  # 20% special enrollment
            effective = date(COVERAGE_YEAR, month, 1)
            status = random.choices(["ACTIVE", "PENDING", "CANCELLED", "TERMINATED"],
                                    weights=[88, 4, 4, 4])[0]
            termination = None
            if status == "CANCELLED":
                termination = effective
            elif status == "TERMINATED":
                end_month = min(month + random.randint(2, 4), 12)
                termination = date(COVERAGE_YEAR, end_month, 1) - timedelta(days=1)
            enr_id += 1
            enrollments.append((enr_id, m_id, plan, COVERAGE_YEAR, effective, termination,
                                status, rate_lookup[(plan, age_band)]))
    return applications, members, eligibility, enrollments


def write_csv(path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(header)
        writer.writerows(rows)
    print(f"  wrote {len(rows):>5} rows -> {path}")


def load_sqlserver(applications, members, eligibility, enrollments):
    conn = pyodbc.connect(SQLSERVER_CONN)   # autocommit is OFF -> one transaction
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*) FROM dbo.applications")
    if cur.fetchone()[0] > 0:
        print("SQL Server already has data - skipping load.")
        conn.close()
        return
    try:
        # Parents before children, or foreign keys reject the rows
        cur.executemany("""INSERT INTO dbo.applications
            (application_id, coverage_year, state_code, application_status, submitted_date)
            VALUES (?,?,?,?,?)""", applications)
        cur.executemany("""INSERT INTO dbo.members
            (member_id, application_id, state_code, age_band, household_size)
            VALUES (?,?,?,?,?)""", members)
        cur.executemany("""INSERT INTO dbo.eligibility
            (eligibility_id, member_id, eligibility_status, effective_date, income_band)
            VALUES (?,?,?,?,?)""", eligibility)
        cur.executemany("""INSERT INTO dbo.enrollments
            (enrollment_id, member_id, plan_id, coverage_year, effective_date,
             termination_date, status, monthly_premium)
            VALUES (?,?,?,?,?,?,?,?)""", enrollments)
        conn.commit()      # all-or-nothing
        print("SQL Server load committed.")
    except Exception:
        conn.rollback()    # any failure -> nothing is saved
        raise
    finally:
        conn.close()


def main():
    print("Reference data (PostgreSQL system):")
    issuers, plans, rates, service_areas = build_reference_data()
    write_csv(OUT_DIR / "issuers.csv", ["issuer_id", "issuer_name", "state_code", "active_flag"], issuers)
    write_csv(OUT_DIR / "plans.csv", ["plan_id", "issuer_id", "plan_name", "metal_level",
                                      "coverage_year", "active_flag"], plans)
    write_csv(OUT_DIR / "plan_rates.csv", ["rate_id", "plan_id", "age_band", "monthly_rate",
                                           "coverage_year"], rates)
    write_csv(OUT_DIR / "service_areas.csv", ["service_area_id", "plan_id", "state_code",
                                              "county_code"], service_areas)

    rate_lookup = {(r[1], r[2]): r[3] for r in rates}
    plans_by_state = {}
    for p in plans:
        plans_by_state.setdefault(p[0][5:7], []).append(p[0])

    apps, members, elig, enr = build_source_data(plans_by_state, rate_lookup)
    print("Operational data (SQL Server system):")
    print(f"  applications={len(apps)} members={len(members)} "
          f"eligibility={len(elig)} enrollments={len(enr)}")
    load_sqlserver(apps, members, elig, enr)


if __name__ == "__main__":
    main()
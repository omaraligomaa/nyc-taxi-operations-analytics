"""Export full 24-hour pickup demand from the EXISTING NYC_Taxi_Analytics SQL Server database.

Read-only: does not create, alter, delete or reload database tables.
Run on a computer connected to SQL Server:
python src/export_hourly.py --server localhost --trust-server-certificate
"""
import argparse
import csv
from pathlib import Path
import pyodbc

SQL = """
SELECT DATEPART(HOUR, pickup_datetime) AS pickup_hour,
       COUNT_BIG(*) AS trips
FROM dbo.yellow_trips_raw
WHERE pickup_datetime >= '2025-01-01'
  AND pickup_datetime < '2025-02-01'
  AND dropoff_datetime > pickup_datetime
  AND trip_distance > 0
  AND total_amount > 0
  AND pu_location_id IS NOT NULL
  AND do_location_id IS NOT NULL
GROUP BY DATEPART(HOUR, pickup_datetime)
ORDER BY pickup_hour;
"""

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--server", default="localhost")
    p.add_argument("--database", default="NYC_Taxi_Analytics")
    p.add_argument("--driver", default="ODBC Driver 18 for SQL Server")
    p.add_argument("--trust-server-certificate", action="store_true")
    a = p.parse_args()
    conn_str = (
        f"DRIVER={{{a.driver}}};SERVER={a.server};DATABASE={a.database};"
        f"Trusted_Connection=yes;Encrypt=yes;"
        f"TrustServerCertificate={'yes' if a.trust_server_certificate else 'no'}"
    )
    with pyodbc.connect(conn_str, timeout=30) as cn:
        rows = cn.cursor().execute(SQL).fetchall()
    hours = {int(hour): int(count) for hour, count in rows}
    if set(hours) != set(range(24)):
        raise ValueError("Expected exactly 24 distinct hours (0 through 23).")
    if sum(hours.values()) != 3324156:
        raise ValueError("Totals do not match the original analysis baseline (3,324,156 trips).")
    output = Path(__file__).resolve().parents[1] / "results" / "original_sql_hourly_24h.csv"
    with output.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["pickup_hour", "trips"])
        writer.writerows((i, hours[i]) for i in range(24))
    print(f"Validated 24 hourly bins; exported {sum(hours.values()):,} trips to {output}")

if __name__ == "__main__":
    main()

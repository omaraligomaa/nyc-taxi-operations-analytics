"""Regenerate portfolio PNG/SVG charts from saved original SQL result CSVs.

Run: python src/build_charts.py
This does NOT query SQL Server or validate the saved outputs independently.
"""
from pathlib import Path
import csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"
IMAGES = ROOT / "images"
IMAGES.mkdir(exist_ok=True)

def read_csv(name):
    with (RESULTS / name).open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

def save(name):
    plt.tight_layout()
    for ext in ("png", "svg"):
        plt.savefig(IMAGES / (name + "." + ext), dpi=200, bbox_inches="tight")
    plt.close()

weekday = read_csv("original_sql_weekday_performance.csv")
plt.figure(figsize=(8, 4.8))
plt.bar([r["day_name"] for r in weekday], [float(r["avg_daily_trips"]) for r in weekday])
plt.title("Average Daily Trips by Weekday")
plt.ylabel("Average Daily Trips")
plt.xticks(rotation=25, ha="right")
save("weekday_avg_daily_trips")

zones = read_csv("original_sql_top_pickup_zones.csv")[::-1]
plt.figure(figsize=(9, 5.5))
plt.barh([r["pickup_zone"] for r in zones], [float(r["total_trips"]) for r in zones])
plt.title("Top Pickup Zones by Trip Volume")
plt.xlabel("Trips")
save("top_pickup_zones")

airport = read_csv("original_sql_airport_segments.csv")
plt.figure(figsize=(6, 4.5))
plt.bar([r["segment"] for r in airport], [float(r["avg_charge_usd"]) for r in airport])
plt.title("Average Charge: Airport vs Non-Airport")
plt.ylabel("Average Passenger Charge (USD)")
save("airport_vs_nonairport_charge")

payment = read_csv("original_sql_payment_mix.csv")
plt.figure(figsize=(8, 4.8))
plt.bar([r["payment_method"] for r in payment], [float(r["trip_share_pct"]) for r in payment])
plt.title("Payment Method Share of Selected Trips")
plt.ylabel("Trip Share (%)")
plt.xticks(rotation=25, ha="right")
save("payment_method_share")

borough = read_csv("original_sql_borough_ranking.csv")[:4]
labels = [r["pickup_borough"] for r in borough]
positions = list(range(len(labels)))
width = 0.35
plt.figure(figsize=(8, 4.8))
plt.bar([i - width / 2 for i in positions], [float(r["trip_share_pct"]) for r in borough], width, label="Trip Share %")
plt.bar([i + width / 2 for i in positions], [float(r["charges_share_pct"]) for r in borough], width, label="Charge Share %")
plt.title("Trip Share vs Charge Share by Borough")
plt.ylabel("Share (%)")
plt.xticks(positions, labels, rotation=20, ha="right")
plt.legend()
save("borough_trip_vs_charge_share")

# Full 24-hour chart is generated only after a validated SQL Server export.
hourly_path = RESULTS / "original_sql_hourly_24h.csv"
if hourly_path.exists():
    hours = read_csv("original_sql_hourly_24h.csv")
    by_hour = {int(r["pickup_hour"]): int(r["trips"]) for r in hours}
    if set(by_hour) != set(range(24)) or sum(by_hour.values()) != 3324156:
        raise ValueError("Hourly data must contain hours 0–23 and total 3,324,156 trips.")
    plt.figure(figsize=(12, 5))
    bars = plt.bar([f"{h:02d}" for h in range(24)], [by_hour[h] for h in range(24)])
    plt.title("Pickup Demand Across All 24 Hours — January 2025")
    plt.xlabel("Pickup Hour")
    plt.ylabel("Selected Trips")
    plt.ticklabel_format(style="plain", axis="y")
    from matplotlib.ticker import StrMethodFormatter
    plt.gca().yaxis.set_major_formatter(StrMethodFormatter("{x:,.0f}"))
    plt.bar_label(bars, labels=[f"{by_hour[h]:,}" if h in (4, 17, 18) else "" for h in range(24)], padding=3, fontsize=8)
    save("hourly_demand_24h")

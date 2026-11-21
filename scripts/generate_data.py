"""Generate a synthetic upstream oil & gas dataset (fixed seed, so the README numbers always match).

Raw files are written to data/raw/ and contain deliberate data-quality problems
(duplicates, negative volumes, impossible hours, missing days, sensor spikes)
that the SQL ETL in sql/ has to catch.

Run:  python scripts/generate_data.py
"""
import csv
import math
import random
from datetime import date, datetime, timedelta
from pathlib import Path

random.seed(7)
ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
RAW.mkdir(parents=True, exist_ok=True)

START, END = date(2025, 1, 1), date(2026, 10, 31)
HOURLY_START = date(2026, 8, 1)          # high-frequency window (last 92 days)

FIELDS = {
    "Mesa Field": ["Mesa North", "Mesa South"],
    "Red Creek Field": ["Red Creek A", "Red Creek B"],
    "Sandhill Field": ["Sandhill East", "Sandhill West"],
}
LIFT = ["ESP", "Rod pump", "Gas lift"]

# ---------------- wells ----------------
wells = []
n = 0
for field, leases in FIELDS.items():
    for lease in leases:
        for k in range(3):
            n += 1
            # most wells are already producing; a few new wells come online during the period
            if n in (5, 11, 17):
                first = START + timedelta(days=random.randint(120, 420))
            else:
                first = START - timedelta(days=random.randint(90, 900))
            wells.append({
                "WellID": f"W-{n:03d}",
                "WellName": f"{lease.split()[0]} {random.randint(10, 39)}-{k + 1}H",
                "Field": field,
                "Lease": lease,
                "LiftType": random.choice(LIFT),
                "FirstProdDate": first.isoformat(),
                # Arps hyperbolic decline parameters (type curve)
                "Qi_bopd": random.randint(420, 900),
                "Di_annual": round(random.uniform(0.70, 1.10), 3),
                "b_factor": round(random.uniform(0.8, 1.2), 2),
                "_gor0": random.uniform(1.4, 2.6),          # mcf/bbl
                "_wc0": random.uniform(0.25, 0.45),         # water cut at first prod
                "_perf": random.gauss(0.98, 0.07),          # how the well performs vs its type curve
            })


def arps(w, d):
    """Type-curve oil rate (bbl/d) at a given date."""
    t = (d - date.fromisoformat(w["FirstProdDate"])).days / 365.0
    if t < 0:
        return 0.0
    return w["Qi_bopd"] / (1 + w["b_factor"] * w["Di_annual"] * t) ** (1 / w["b_factor"])


def gor(w, d):
    t = max(0, (d - date.fromisoformat(w["FirstProdDate"])).days / 365.0)
    return w["_gor0"] * (1 + 0.18 * t)


def wcut(w, d):
    t = max(0, (d - date.fromisoformat(w["FirstProdDate"])).days / 365.0)
    return min(0.85, w["_wc0"] + 0.07 * t)


# ---------------- downtime events ----------------
REASONS = [  # reason, category, weight, min h, max h, lift types (None = all)
    ("Pump / ESP failure", "Unplanned", 18, 30, 120, ("ESP", "Rod pump")),
    ("Planned maintenance", "Planned", 30, 4, 14, None),
    ("Facility constraint", "Unplanned", 14, 6, 30, None),
    ("Workover", "Planned", 4, 96, 192, None),
    ("Wellhead / flowline leak", "Unplanned", 10, 8, 48, None),
]
events = []
eid = 0


def add_event(w, start_ts, hours, reason, category):
    global eid
    eid += 1
    events.append({"EventID": f"DT-{eid:05d}", "WellID": w["WellID"],
                   "StartTime": start_ts.strftime("%Y-%m-%d %H:%M"),
                   "EndTime": (start_ts + timedelta(hours=hours)).strftime("%Y-%m-%d %H:%M"),
                   "Reason": reason, "Category": category})


for w in wells:
    d = max(START, date.fromisoformat(w["FirstProdDate"]))
    while True:
        d += timedelta(days=int(random.expovariate(1 / 26)) + 1)
        if d > END:
            break
        options = [r for r in REASONS if r[5] is None or w["LiftType"] in r[5]]
        r = random.choices(options, weights=[o[2] for o in options])[0]
        hours = random.randint(r[3], r[4])
        add_event(w, datetime(d.year, d.month, d.day, random.randint(0, 23)), hours, r[0], r[1])

# field-wide events (all wells in the field go down together)
for field in FIELDS:
    for _ in range(9):
        d = START + timedelta(days=random.randint(0, (END - START).days))
        reason, hours = random.choice([("Power outage", random.randint(3, 14)), ("Weather", random.randint(12, 40))])
        st = datetime(d.year, d.month, d.day, random.randint(0, 23))
        for w in wells:
            if w["Field"] == field and date.fromisoformat(w["FirstProdDate"]) <= d:
                add_event(w, st, hours, reason, "Unplanned")

# downtime hours per well per day (events can span midnight)
down = {}
for e in events:
    s = datetime.strptime(e["StartTime"], "%Y-%m-%d %H:%M")
    f = datetime.strptime(e["EndTime"], "%Y-%m-%d %H:%M")
    cur = s
    while cur < f:
        nxt = min(f, datetime(cur.year, cur.month, cur.day) + timedelta(days=1))
        key = (e["WellID"], cur.date())
        down[key] = min(24.0, down.get(key, 0) + (nxt - cur).total_seconds() / 3600)
        cur = nxt

# ---------------- daily production (well tests / allocation) ----------------
daily = []
truth = {}   # clean values, used to build sales tickets and hourly data
for w in wells:
    d = max(START, date.fromisoformat(w["FirstProdDate"]))
    while d <= END:
        dh = down.get((w["WellID"], d), 0.0)
        on = round(24 - dh, 1)
        rate = arps(w, d) * w["_perf"] * random.gauss(1, 0.045)
        oil = max(0.0, rate * on / 24)
        wc = wcut(w, d)
        gas = oil * gor(w, d) * random.gauss(1, 0.03)
        water = oil * wc / (1 - wc) * random.gauss(1, 0.04)
        row = {"ProdDate": d.isoformat(), "WellID": w["WellID"], "HoursOn": on,
               "OilBbl": round(oil, 1), "GasMcf": round(gas, 1), "WaterBbl": round(water, 1)}
        truth[(w["WellID"], d)] = dict(row)
        daily.append(row)
        d += timedelta(days=1)

# ---- inject data-quality problems into the raw extract ----
raw_daily = [dict(r) for r in daily]
idx = list(range(len(raw_daily)))
random.shuffle(idx)
missing = set(idx[:55])                                   # days never reported
for i in idx[55:75]:                                      # negative volumes (sign errors)
    raw_daily[i]["OilBbl"] = -abs(raw_daily[i]["OilBbl"])
for i in idx[75:95]:                                      # impossible hours on
    raw_daily[i]["HoursOn"] = round(random.uniform(24.5, 48), 1)
for i in idx[95:105]:                                     # blank oil volume
    raw_daily[i]["OilBbl"] = ""
dups = [dict(raw_daily[i]) for i in idx[105:145]]         # duplicated rows (re-sent by the field app)
raw_daily = [r for i, r in enumerate(raw_daily) if i not in missing] + dups
raw_daily.sort(key=lambda r: (r["ProdDate"], r["WellID"]))

# ---------------- monthly sales tickets per lease (pipeline / LACT meter) ----------------
sales = []
months = sorted({(d.year, d.month) for (_, d) in truth})
bad_months = {("Red Creek B", (2025, 9)), ("Sandhill East", (2026, 4)), ("Mesa North", (2026, 8))}
for lease in [l for ls in FIELDS.values() for l in ls]:
    lw = {w["WellID"] for w in wells if w["Lease"] == lease}
    for (y, m) in months:
        oil = sum(v["OilBbl"] for (wid, d), v in truth.items() if wid in lw and (d.year, d.month) == (y, m))
        gas = sum(v["GasMcf"] for (wid, d), v in truth.items() if wid in lw and (d.year, d.month) == (y, m))
        if oil == 0:
            continue
        shrink = random.gauss(0.992, 0.006)                # normal shrinkage / meter tolerance
        if (lease, (y, m)) in bad_months:
            shrink = random.choice([0.90, 0.92, 1.09])      # meter problem -> must be flagged
        sales.append({"MonthStart": date(y, m, 1).isoformat(), "Lease": lease,
                      "OilSoldBbl": round(oil * shrink, 0),
                      "GasSoldMcf": round(gas * random.gauss(0.975, 0.01), 0)})

# ---------------- lease operating expenses (monthly, by category) ----------------
loe = []
for lease in [l for ls in FIELDS.values() for l in ls]:
    lw = [w for w in wells if w["Lease"] == lease]
    lwid = {w["WellID"] for w in lw}
    for (y, m) in months:
        fluids = sum(v["OilBbl"] + v["WaterBbl"] for (wid, d), v in truth.items() if wid in lwid and (d.year, d.month) == (y, m))
        water = sum(v["WaterBbl"] for (wid, d), v in truth.items() if wid in lwid and (d.year, d.month) == (y, m))
        active = sum(1 for w in lw if date.fromisoformat(w["FirstProdDate"]) <= date(y, m, 28))
        if active == 0:
            continue
        repairs = 0.0
        for e in events:
            if e["WellID"] in lwid and e["StartTime"][:7] == f"{y}-{m:02d}":
                if e["Reason"] == "Pump / ESP failure":
                    repairs += random.uniform(18000, 45000)
                elif e["Reason"] == "Workover":
                    repairs += random.uniform(70000, 140000)
                elif e["Reason"] == "Wellhead / flowline leak":
                    repairs += random.uniform(3000, 9000)
        for cat, amt in [("Labor & supervision", 9500 * active ** 0.6 * random.gauss(1, 0.03)),
                         ("Power & fuel", fluids * 0.55 * random.gauss(1, 0.05)),
                         ("Chemicals", fluids * 0.22 * random.gauss(1, 0.08)),
                         ("Water disposal", water * 0.80 * random.gauss(1, 0.03)),
                         ("Repairs & workovers", repairs)]:
            if amt > 0:
                loe.append({"MonthStart": date(y, m, 1).isoformat(), "Lease": lease, "Category": cat, "AmountUSD": round(amt, 2)})

# ---------------- high-frequency SCADA readings (hourly, last 92 days) ----------------
hourly = []
for w in wells:
    if date.fromisoformat(w["FirstProdDate"]) > HOURLY_START:
        continue
    d = HOURLY_START
    shut_in = 0
    while d <= END:
        t = truth.get((w["WellID"], d))
        dh = 24 - t["HoursOn"]
        # place the downtime at the start of the day for the hourly trace
        rate24 = t["OilBbl"] / (t["HoursOn"] / 24) if t["HoursOn"] > 0 else 0
        for h in range(24):
            off = h < dh
            shut_in = shut_in + 1 if off else 0
            flow = 0.0 if off else max(0.0, rate24 * random.gauss(1, 0.06))
            tbg = 180 + 4.5 * min(shut_in, 30) + random.gauss(0, 6) if off else 120 + 0.08 * flow + random.gauss(0, 5)
            csg = tbg + 60 + random.gauss(0, 8)
            hourly.append({"ReadingTime": f"{d.isoformat()} {h:02d}:00", "WellID": w["WellID"],
                           "TubingPsi": round(tbg, 1), "CasingPsi": round(csg, 1), "OilRateBopd": round(flow, 1)})
        d += timedelta(days=1)
spikes = random.sample(range(len(hourly)), 35)            # sensor glitches
for i in spikes:
    hourly[i]["TubingPsi"] = random.choice([0.0, 9999.0])

# allocation errors: a few daily volumes that disagree with what SCADA measured
recent = [r for r in raw_daily if r["ProdDate"] >= HOURLY_START.isoformat()
          and isinstance(r["OilBbl"], float) and r["OilBbl"] > 50]
for r in random.sample(recent, 8):
    r["OilBbl"] = round(r["OilBbl"] * random.choice([0.78, 0.82, 1.2, 1.25]), 1)


def write(name, rows, cols=None):
    cols = cols or [c for c in rows[0] if not c.startswith("_")]
    with open(RAW / name, "w", newline="", encoding="utf-8") as fh:
        wr = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        wr.writeheader()
        wr.writerows(rows)
    print(f"{name}: {len(rows):,} rows")


write("wells.csv", wells)
write("daily_production.csv", raw_daily)
write("downtime_events.csv", events)
write("sales_tickets.csv", sales)
write("loe_monthly.csv", loe)
write("scada_hourly.csv", hourly)

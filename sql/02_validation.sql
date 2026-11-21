-- 02_validation.sql
-- Data-quality checks. Every problem found becomes one row in dq_issues, with the action the ETL takes.
-- Nothing is fixed silently: the Power BI report shows this table on its own page.

DROP TABLE IF EXISTS dq_issues;
CREATE TABLE dq_issues (
    check_name  TEXT,
    severity    TEXT,      -- Error = row rejected, Warning = row kept and flagged
    source      TEXT,
    well_id     TEXT,
    lease       TEXT,
    issue_date  TEXT,
    detail      TEXT,
    action      TEXT
);

-- 1. Duplicate well-day rows (the field app re-sent the record)
INSERT INTO dq_issues
SELECT 'Duplicate well-day', 'Warning', 'daily_production', well_id, NULL, prod_date,
       'Copy #' || dup_rank || ' of the same well-day', 'Removed duplicate, kept first copy'
FROM stg_daily_production
WHERE dup_rank > 1;

-- 2. Negative volumes (sign error at source)
INSERT INTO dq_issues
SELECT 'Negative volume', 'Error', 'daily_production', well_id, NULL, prod_date,
       'Oil = ' || oil_bbl || ' bbl', 'Row rejected'
FROM stg_daily_production
WHERE dup_rank = 1 AND (oil_bbl < 0 OR gas_mcf < 0 OR water_bbl < 0);

-- 3. Missing oil volume
INSERT INTO dq_issues
SELECT 'Missing volume', 'Error', 'daily_production', well_id, NULL, prod_date,
       'Oil volume is blank', 'Row rejected'
FROM stg_daily_production
WHERE dup_rank = 1 AND oil_bbl IS NULL;

-- 4. Hours on outside 0-24
INSERT INTO dq_issues
SELECT 'Hours on out of range', 'Warning', 'daily_production', well_id, NULL, prod_date,
       'Hours on = ' || hours_on, 'Capped at 24 h'
FROM stg_daily_production
WHERE dup_rank = 1 AND (hours_on > 24 OR hours_on < 0);

-- 5. Missing days: gaps between consecutive reports of the same well (LAG window function)
INSERT INTO dq_issues
SELECT 'Missing day', 'Warning', 'daily_production', well_id, NULL, DATE(prev_date, '+1 day'),
       CAST(gap_days - 1 AS INTEGER) || ' day(s) not reported before ' || prod_date,
       'Left blank (not imputed); forecast still counts'
FROM (
    SELECT well_id, prod_date,
           LAG(prod_date) OVER (PARTITION BY well_id ORDER BY prod_date) AS prev_date,
           JULIANDAY(prod_date) - JULIANDAY(LAG(prod_date) OVER (PARTITION BY well_id ORDER BY prod_date)) AS gap_days
    FROM stg_daily_production
    WHERE dup_rank = 1
)
WHERE gap_days > 1;

-- 6. SCADA sensor spikes (pressure outside the physical range of the gauge)
INSERT INTO dq_issues
SELECT 'Sensor spike', 'Warning', 'scada_hourly', well_id, NULL, reading_date,
       'Tubing pressure = ' || tubing_psi || ' psi at ' || STRFTIME('%H:%M', reading_time), 'Reading set to NULL'
FROM stg_scada_hourly
WHERE tubing_psi <= 0 OR tubing_psi > 3000;

-- 7. High-frequency vs daily: oil implied by hourly flow rates vs the reported daily volume
INSERT INTO dq_issues
SELECT 'SCADA vs daily volume', 'Warning', 'scada_hourly', h.well_id, NULL, h.reading_date,
       'SCADA ' || ROUND(h.scada_oil, 0) || ' bbl vs reported ' || ROUND(d.oil_bbl, 0) || ' bbl ('
           || PRINTF('%+.1f', 100.0 * (h.scada_oil - d.oil_bbl) / d.oil_bbl) || '%)',
       'Kept; review allocation'
FROM (
    SELECT well_id, reading_date, SUM(oil_rate_bopd) / 24.0 AS scada_oil
    FROM stg_scada_hourly
    GROUP BY well_id, reading_date
) h
JOIN stg_daily_production d
  ON d.well_id = h.well_id AND d.prod_date = h.reading_date AND d.dup_rank = 1
WHERE d.oil_bbl > 20
  AND ABS(h.scada_oil - d.oil_bbl) / d.oil_bbl > 0.10;

-- 8. Sales reconciliation: allocated well volumes vs the lease sales meter (monthly, > 3% difference)
INSERT INTO dq_issues
SELECT 'Sales vs allocation', 'Warning', 'sales_tickets', NULL, s.lease, s.month_start,
       'Allocated ' || CAST(ROUND(a.oil_bbl) AS INTEGER) || ' bbl vs sold ' || CAST(s.oil_sold_bbl AS INTEGER) || ' bbl ('
           || PRINTF('%+.1f', 100.0 * (s.oil_sold_bbl - a.oil_bbl) / a.oil_bbl) || '%)',
       'Investigate meter / allocation'
FROM stg_sales_tickets s
JOIN (
    SELECT w.lease, DATE(d.prod_date, 'start of month') AS month_start, SUM(d.oil_bbl) AS oil_bbl
    FROM stg_daily_production d
    JOIN stg_wells w ON w.well_id = d.well_id
    WHERE d.dup_rank = 1 AND d.oil_bbl >= 0
    GROUP BY w.lease, DATE(d.prod_date, 'start of month')
) a ON a.lease = s.lease AND a.month_start = s.month_start
WHERE ABS(s.oil_sold_bbl - a.oil_bbl) / a.oil_bbl > 0.03;

UPDATE dq_issues SET lease = (SELECT lease FROM stg_wells w WHERE w.well_id = dq_issues.well_id)
WHERE lease IS NULL;

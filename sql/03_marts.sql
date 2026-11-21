-- 03_marts.sql
-- Clean, report-ready tables (exported to data/mart/ and loaded by Power BI).
-- Heavy work (dedup, rejection, type curve, hourly roll-ups) is done here so the model stays small and fast.

-- ---------- dimension: wells ----------
DROP TABLE IF EXISTS mart_dim_well;
CREATE TABLE mart_dim_well AS
SELECT well_id, well_name, field, lease, lift_type, first_prod_date,
       CASE WHEN first_prod_date >= '2025-01-01' THEN 'New well' ELSE 'Base well' END AS well_vintage
FROM stg_wells;

-- ---------- fact: daily production on a full calendar spine ----------
-- Every well has one row per day since first production (or 2025-01-01), even when the day was
-- not reported or was rejected, so the type-curve forecast and "missing day" counts stay complete.
DROP TABLE IF EXISTS mart_fact_daily;
CREATE TABLE mart_fact_daily AS
WITH RECURSIVE calendar(d) AS (
    SELECT DATE('2025-01-01')
    UNION ALL
    SELECT DATE(d, '+1 day') FROM calendar WHERE d < (SELECT MAX(prod_date) FROM stg_daily_production)
),
spine AS (
    SELECT c.d AS prod_date, w.*
    FROM calendar c
    JOIN stg_wells w ON c.d >= w.first_prod_date
),
clean AS (
    SELECT well_id, prod_date,
           MIN(MAX(hours_on, 0), 24) AS hours_on,           -- cap impossible hours
           oil_bbl, gas_mcf, water_bbl
    FROM stg_daily_production
    WHERE dup_rank = 1                                        -- drop duplicates
      AND oil_bbl IS NOT NULL AND oil_bbl >= 0                -- reject blank / negative
      AND gas_mcf >= 0 AND water_bbl >= 0
),
forecast AS (
    -- Arps hyperbolic decline: q(t) = qi / (1 + b * Di * t)^(1/b), t in years since first production
    SELECT s.prod_date, s.well_id,
           s.qi_bopd / POW(1 + s.b_factor * s.di_annual * ((JULIANDAY(s.prod_date) - JULIANDAY(s.first_prod_date)) / 365.0),
                           1.0 / s.b_factor) AS forecast_oil_bbl
    FROM spine s
),
well_gor AS (
    SELECT well_id, SUM(gas_mcf) / SUM(oil_bbl) AS avg_gor FROM clean GROUP BY well_id
)
SELECT
    f.prod_date,
    f.well_id,
    c.hours_on,
    c.oil_bbl,
    c.gas_mcf,
    c.water_bbl,
    ROUND(c.oil_bbl + c.gas_mcf / 6.0, 1)                         AS boe,
    ROUND(f.forecast_oil_bbl, 1)                                  AS forecast_oil_bbl,
    -- forecast BOE converts forecast oil with the well's average GOR (6 mcf = 1 BOE)
    ROUND(f.forecast_oil_bbl * (1 + g.avg_gor / 6.0), 1)          AS forecast_boe,
    CASE WHEN c.hours_on IS NULL THEN NULL
         ELSE ROUND(f.forecast_oil_bbl * (24 - c.hours_on) / 24.0, 1) END AS deferred_oil_bbl,
    CASE WHEN c.well_id IS NULL THEN 1 ELSE 0 END                  AS is_missing
FROM forecast f
JOIN well_gor g ON g.well_id = f.well_id
LEFT JOIN clean c ON c.well_id = f.well_id AND c.prod_date = f.prod_date;

-- ---------- fact: downtime events ----------
DROP TABLE IF EXISTS mart_fact_downtime;
CREATE TABLE mart_fact_downtime AS
SELECT e.event_id, e.well_id, DATE(e.start_time) AS start_date, e.start_time, e.end_time,
       e.duration_h, e.reason, e.category,
       ROUND(COALESCE(d.forecast_oil_bbl, 0) * e.duration_h / 24.0, 1) AS est_deferred_oil_bbl
FROM stg_downtime_events e
LEFT JOIN mart_fact_daily d ON d.well_id = e.well_id AND d.prod_date = DATE(e.start_time)
WHERE DATE(e.start_time) <= (SELECT MAX(prod_date) FROM mart_fact_daily);

-- ---------- fact: lease operating expenses ----------
DROP TABLE IF EXISTS mart_fact_loe;
CREATE TABLE mart_fact_loe AS
SELECT month_start, lease, category, ROUND(amount_usd, 2) AS amount_usd FROM stg_loe_monthly;

-- ---------- fact: sales reconciliation (lease x month x product) ----------
DROP TABLE IF EXISTS mart_fact_sales_recon;
CREATE TABLE mart_fact_sales_recon AS
WITH alloc AS (
    SELECT w.lease, DATE(d.prod_date, 'start of month') AS month_start,
           SUM(d.oil_bbl) AS oil_bbl, SUM(d.gas_mcf) AS gas_mcf
    FROM mart_fact_daily d
    JOIN stg_wells w ON w.well_id = d.well_id
    GROUP BY w.lease, DATE(d.prod_date, 'start of month')
)
SELECT s.month_start, s.lease, 'Oil (bbl)' AS product,
       ROUND(a.oil_bbl, 0) AS allocated_volume, s.oil_sold_bbl AS sold_volume
FROM stg_sales_tickets s JOIN alloc a ON a.lease = s.lease AND a.month_start = s.month_start
UNION ALL
SELECT s.month_start, s.lease, 'Gas (mcf)',
       ROUND(a.gas_mcf, 0), s.gas_sold_mcf
FROM stg_sales_tickets s JOIN alloc a ON a.lease = s.lease AND a.month_start = s.month_start;

-- ---------- fact: hourly SCADA (spikes removed) ----------
DROP TABLE IF EXISTS mart_fact_scada_hourly;
CREATE TABLE mart_fact_scada_hourly AS
SELECT reading_time, reading_date, reading_hour, well_id,
       CASE WHEN tubing_psi <= 0 OR tubing_psi > 3000 THEN NULL ELSE tubing_psi END AS tubing_psi,
       casing_psi, oil_rate_bopd
FROM stg_scada_hourly;

-- ---------- data-quality log ----------
DROP TABLE IF EXISTS mart_dq_issues;
CREATE TABLE mart_dq_issues AS
SELECT ROW_NUMBER() OVER (ORDER BY issue_date, check_name, well_id) AS issue_id, * FROM dq_issues;

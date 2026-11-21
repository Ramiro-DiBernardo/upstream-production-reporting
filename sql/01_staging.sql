-- 01_staging.sql
-- Raw CSVs are loaded as text into raw_* tables by scripts/run_etl.py.
-- Staging casts types, trims blanks to NULL and numbers repeated rows so later steps can deduplicate.

DROP TABLE IF EXISTS stg_wells;
CREATE TABLE stg_wells AS
SELECT
    WellID                       AS well_id,
    WellName                     AS well_name,
    Field                        AS field,
    Lease                        AS lease,
    LiftType                     AS lift_type,
    DATE(FirstProdDate)          AS first_prod_date,
    CAST(Qi_bopd    AS REAL)     AS qi_bopd,
    CAST(Di_annual  AS REAL)     AS di_annual,
    CAST(b_factor   AS REAL)     AS b_factor
FROM raw_wells;

DROP TABLE IF EXISTS stg_daily_production;
CREATE TABLE stg_daily_production AS
SELECT
    rowid                                        AS src_row,
    DATE(ProdDate)                               AS prod_date,
    WellID                                       AS well_id,
    CAST(NULLIF(TRIM(HoursOn), '')  AS REAL)     AS hours_on,
    CAST(NULLIF(TRIM(OilBbl), '')   AS REAL)     AS oil_bbl,
    CAST(NULLIF(TRIM(GasMcf), '')   AS REAL)     AS gas_mcf,
    CAST(NULLIF(TRIM(WaterBbl), '') AS REAL)     AS water_bbl,
    ROW_NUMBER() OVER (PARTITION BY WellID, ProdDate ORDER BY rowid) AS dup_rank
FROM raw_daily_production;

DROP TABLE IF EXISTS stg_downtime_events;
CREATE TABLE stg_downtime_events AS
SELECT
    EventID                                                     AS event_id,
    WellID                                                      AS well_id,
    DATETIME(StartTime)                                         AS start_time,
    DATETIME(EndTime)                                           AS end_time,
    ROUND((JULIANDAY(EndTime) - JULIANDAY(StartTime)) * 24, 1)  AS duration_h,
    Reason                                                      AS reason,
    Category                                                    AS category
FROM raw_downtime_events;

DROP TABLE IF EXISTS stg_sales_tickets;
CREATE TABLE stg_sales_tickets AS
SELECT DATE(MonthStart) AS month_start, Lease AS lease,
       CAST(OilSoldBbl AS REAL) AS oil_sold_bbl, CAST(GasSoldMcf AS REAL) AS gas_sold_mcf
FROM raw_sales_tickets;

DROP TABLE IF EXISTS stg_loe_monthly;
CREATE TABLE stg_loe_monthly AS
SELECT DATE(MonthStart) AS month_start, Lease AS lease, Category AS category, CAST(AmountUSD AS REAL) AS amount_usd
FROM raw_loe_monthly;

DROP TABLE IF EXISTS stg_scada_hourly;
CREATE TABLE stg_scada_hourly AS
SELECT DATETIME(ReadingTime) AS reading_time, DATE(ReadingTime) AS reading_date,
       CAST(STRFTIME('%H', ReadingTime) AS INTEGER) AS reading_hour, WellID AS well_id,
       CAST(TubingPsi AS REAL) AS tubing_psi, CAST(CasingPsi AS REAL) AS casing_psi,
       CAST(OilRateBopd AS REAL) AS oil_rate_bopd
FROM raw_scada_hourly;

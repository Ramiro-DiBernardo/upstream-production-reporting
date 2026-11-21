# DAX measures

All 51 measures live in the `_Measures` table, grouped in display folders. Key totals were cross-checked against the SQL marts (see README).

## 1. Volumes

### Oil (bbl)

```dax
SUM(Production[OilBbl])
```

### Gas (mcf)

```dax
SUM(Production[GasMcf])
```

### Water (bbl)

```dax
SUM(Production[WaterBbl])
```

### BOE

```dax
SUM(Production[BOE])
```

### Calendar Days

```dax
DISTINCTCOUNT(Production[ProdDate])
```

### Avg Daily BOE

```dax
DIVIDE([BOE], [Calendar Days])
```

### Avg Daily Oil

```dax
DIVIDE([Oil (bbl)], [Calendar Days])
```

### Current Rate (7d BOE/d)

```dax
VAR _last = MAX(Production[ProdDate])
RETURN
CALCULATE([Avg Daily BOE], DATESINPERIOD('Date'[Date], _last, -7, DAY))
```

### Water Cut %

```dax
DIVIDE([Water (bbl)], [Oil (bbl)] + [Water (bbl)])
```

### GOR (scf/bbl)

```dax
DIVIDE([Gas (mcf)] * 1000, [Oil (bbl)])
```

### BOE MoM %

```dax
VAR _cur = [Avg Daily BOE]
VAR _prev = CALCULATE([Avg Daily BOE], DATEADD('Date'[Date], -1, MONTH))
RETURN
IF(NOT ISBLANK(_prev), DIVIDE(_cur - _prev, _prev))
```

### BOE 30d Rolling Avg

```dax
CALCULATE([Avg Daily BOE], DATESINPERIOD('Date'[Date], MAX('Date'[Date]), -30, DAY))
```

## 2. Forecast

### Forecast BOE

```dax
SUM(Production[ForecastBOE])
```

### Forecast Daily BOE

```dax
DIVIDE([Forecast BOE], [Calendar Days])
```

### Variance vs Forecast (BOE)

```dax
[BOE] - [Forecast BOE]
```

### Variance vs Forecast %

```dax
DIVIDE([BOE] - [Forecast BOE], [Forecast BOE])
```

### Deferred Oil (bbl)

```dax
SUM(Production[DeferredOilBbl])
```

### Well Rank (BOE)

```dax
IF(HASONEVALUE(Wells[Well]), RANKX(ALLSELECTED(Wells), [BOE], , DESC, DENSE))
```

## 3. Uptime & downtime

### Hours On

```dax
SUM(Production[HoursOn])
```

### Available Hours

```dax
24 * CALCULATE(COUNTROWS(Production), NOT ISBLANK(Production[HoursOn]))
```

### Uptime %

```dax
DIVIDE([Hours On], [Available Hours])
```

### Downtime Hours

```dax
[Available Hours] - [Hours On]
```

### Downtime Events

```dax
COUNTROWS(Downtime)
```

### Unplanned Events

```dax
CALCULATE([Downtime Events], Downtime[Category] = "Unplanned")
```

### Event Hours

```dax
SUM(Downtime[DurationH])
```

### Event Deferred Oil (bbl)

```dax
SUM(Downtime[EstDeferredOilBbl])
```

### Days Between Unplanned Events

```dax
DIVIDE(CALCULATE(COUNTROWS(Production), Production[HoursOn] > 0), [Unplanned Events])
```

### Top Downtime Reason

```dax
MAXX(TOPN(1, VALUES(Downtime[Reason]), [Event Hours], DESC), Downtime[Reason])
```

## 4. Cost

### LOE ($)

```dax
SUM(LOE[AmountUSD])
```

### LOE per BOE

```dax
-- LOE is booked per lease, so it cannot be split by well: blank at well level instead of a wrong number
IF(ISFILTERED(Wells), BLANK(), DIVIDE([LOE ($)], [BOE]))
```

### Repairs & Workovers ($)

```dax
CALCULATE([LOE ($)], LOE[Cost Category] = "Repairs & workovers")
```

### Repairs % of LOE

```dax
DIVIDE([Repairs & Workovers ($)], [LOE ($)])
```

## 5. Reconciliation & data quality

### Allocated Oil (bbl)

```dax
CALCULATE(SUM('Sales Recon'[AllocatedVolume]), 'Sales Recon'[Product] = "Oil (bbl)")
```

### Sold Oil (bbl)

```dax
CALCULATE(SUM('Sales Recon'[SoldVolume]), 'Sales Recon'[Product] = "Oil (bbl)")
```

### Sales vs Allocation %

```dax
DIVIDE([Sold Oil (bbl)] - [Allocated Oil (bbl)], [Allocated Oil (bbl)])
```

### Abs Recon Gap %

```dax
ABS([Sales vs Allocation %])
```

### Recon Status

```dax
VAR _gap = [Abs Recon Gap %]
RETURN
IF(NOT ISBLANK(_gap), IF(_gap > 0.03, "Investigate", "OK"))
```

### DQ Issues

```dax
COUNTROWS('DQ Issues')
```

### Rows Rejected

```dax
CALCULATE([DQ Issues], 'DQ Issues'[Severity] = "Error")
```

### Missing Well-Days

```dax
CALCULATE(COUNTROWS(Production), Production[IsMissing] = 1)
```

### Data Completeness %

```dax
1 - DIVIDE([Missing Well-Days], COUNTROWS(Production))
```

## 6. SCADA (hourly)

### Avg Tubing Pressure (psi)

```dax
AVERAGE('SCADA Hourly'[TubingPsi])
```

### Avg Casing Pressure (psi)

```dax
AVERAGE('SCADA Hourly'[CasingPsi])
```

### Avg Oil Rate (bopd)

```dax
AVERAGE('SCADA Hourly'[OilRateBopd])
```

### SCADA Oil (bbl)

```dax
SUM('SCADA Hourly'[OilRateBopd]) / 24
```

### SCADA vs Reported %

```dax
VAR _scada = [SCADA Oil (bbl)]
VAR _reported = CALCULATE([Oil (bbl)], TREATAS(VALUES('SCADA Hourly'[ReadingDate]), 'Date'[Date]))
RETURN
DIVIDE(_scada - _reported, _reported)
```

### Shut-in Hours

```dax
CALCULATE(COUNTROWS('SCADA Hourly'), 'SCADA Hourly'[OilRateBopd] = 0)
```

## 7. HTML

### HTML KPI Strip

```dax
VAR _green = "#1B9E5A"
VAR _amber = "#E0A100"
VAR _red = "#D64545"
VAR _var = [Variance vs Forecast %]
VAR _up = [Uptime %]
VAR _comp = [Data Completeness %]
VAR _varC = SWITCH(TRUE(), _var >= 0, _green, _var >= -0.05, _amber, _red)
VAR _upC = SWITCH(TRUE(), _up >= 0.95, _green, _up >= 0.9, _amber, _red)
VAR _compC = IF(_comp >= 0.99, _green, _amber)
VAR _tile = "flex:1;margin:5px;padding:12px 14px;background:#FFFFFF;border-radius:10px;border:1px solid #D6DBE4;border-left:6px solid "
VAR _lbl = "<div style='font:600 12px Segoe UI;color:#5B6475;text-transform:uppercase;letter-spacing:.5px'>"
VAR _val = "<div style='font:700 26px Segoe UI;margin-top:4px;color:"
VAR _sub = "<div style='font:12px Segoe UI;color:#5B6475;margin-top:2px'>"
RETURN
"<div style='display:flex;font-family:Segoe UI'>"
    & "<div style='" & _tile & "#0B6E4F'>" & _lbl & "Current rate</div>" & _val & "#14213D'>" & FORMAT([Current Rate (7d BOE/d)], "#,0") & " BOE/d</div>"
    & _sub & "Last 7 days &middot; " & FORMAT([Avg Daily Oil], "#,0") & " bbl/d oil avg</div></div>"
    & "<div style='" & _tile & _varC & "'>" & _lbl & "vs type curve</div>" & _val & _varC & "'>" & FORMAT(_var, "+0.0%;-0.0%") & "</div>"
    & _sub & FORMAT([Variance vs Forecast (BOE)], "+#,0;-#,0") & " BOE vs forecast</div></div>"
    & "<div style='" & _tile & _upC & "'>" & _lbl & "Uptime</div>" & _val & _upC & "'>" & FORMAT(_up, "0.0%") & "</div>"
    & _sub & FORMAT([Deferred Oil (bbl)], "#,0") & " bbl deferred</div></div>"
    & "<div style='" & _tile & "#7A4DFF'>" & _lbl & "Lifting cost</div>" & _val & "#14213D'>" & FORMAT([LOE per BOE], "$0.00") & "/BOE</div>"
    & _sub & FORMAT([LOE ($)], "$#,0") & " LOE</div></div>"
    & "<div style='" & _tile & _compC & "'>" & _lbl & "Data completeness</div>" & _val & _compC & "'>" & FORMAT(_comp, "0.0%") & "</div>"
    & _sub & FORMAT([DQ Issues], "#,0") & " issues logged</div></div>"
& "</div>"
```

### HTML Field Cards

```dax
VAR _cards =
    CONCATENATEX(
        VALUES(Leases[Field]),
        VAR _var = [Variance vs Forecast %]
        VAR _up = [Uptime %]
        VAR _c = SWITCH(TRUE(), _var >= 0, "#1B9E5A", _var >= -0.05, "#E0A100", "#D64545")
        RETURN
        "<div style='flex:1;margin:5px;padding:12px;background:#FFFFFF;border:1px solid #D6DBE4;border-radius:10px'>"
            & "<div style='display:flex;justify-content:space-between;align-items:center'>"
            & "<span style='font:700 15px Segoe UI;color:#14213D'>" & Leases[Field] & "</span>"
            & "<span style='font:700 12px Segoe UI;color:#FFFFFF;background:" & _c & ";padding:2px 8px;border-radius:10px'>" & FORMAT(_var, "+0.0%;-0.0%") & "</span></div>"
            & "<div style='font:700 24px Segoe UI;color:#0B6E4F;margin-top:6px'>" & FORMAT([Avg Daily BOE], "#,0") & " <span style='font:13px Segoe UI;color:#5B6475'>BOE/d</span></div>"
            & "<div style='font:12px Segoe UI;color:#5B6475;margin-top:4px'>Water cut " & FORMAT([Water Cut %], "0%") & " &middot; GOR " & FORMAT([GOR (scf/bbl)], "#,0") & " scf/bbl</div>"
            & "<div style='font:12px Segoe UI;color:#5B6475;margin-top:8px'>Uptime " & FORMAT(_up, "0.0%") & "</div>"
            & "<div style='height:8px;background:#E9EDF3;border-radius:4px;margin-top:3px'><div style='width:" & FORMAT(_up * 100, "0") & "%;height:8px;background:#0B6E4F;border-radius:4px'></div></div>"
        & "</div>",
        "",
        [Avg Daily BOE], DESC
    )
RETURN
"<div style='display:flex;font-family:Segoe UI'>" & _cards & "</div>"
```

### HTML Well Alerts

```dax
VAR _wells =
    FILTER(
        ADDCOLUMNS(VALUES(Wells[Well]), "@var", [Variance vs Forecast %], "@up", [Uptime %], "@def", [Deferred Oil (bbl)]),
        [@var] < -0.10 || [@up] < 0.92
    )
VAR _n = COUNTROWS(_wells)
VAR _rows =
    CONCATENATEX(
        TOPN(6, _wells, [@var], ASC),
        VAR _isPerf = [@var] < -0.10
        RETURN
        "<div style='display:flex;align-items:center;padding:7px 0;border-bottom:1px solid #EEF1F5;font:13px Segoe UI;color:#14213D'>"
            & "<span style='width:10px;height:10px;border-radius:5px;margin-right:9px;background:" & IF(_isPerf, "#D64545", "#E0A100") & "'></span>"
            & "<span style='flex:1;font-weight:600'>" & Wells[Well] & "</span>"
            & "<span style='width:90px;text-align:right;color:" & IF(_isPerf, "#D64545", "#5B6475") & "'>" & FORMAT([@var], "+0%;-0%") & " vs TC</span>"
            & "<span style='width:90px;text-align:right;color:" & IF([@up] < 0.92, "#E0A100", "#5B6475") & "'>" & FORMAT([@up], "0%") & " up</span>"
            & "<span style='width:110px;text-align:right;color:#5B6475'>" & FORMAT([@def], "#,0") & " bbl def.</span>"
        & "</div>",
        "",
        [@var], ASC
    )
RETURN
"<div style='font-family:Segoe UI;padding:4px 8px'>"
    & "<div style='font:700 16px Segoe UI;color:#14213D'>Wells to review <span style='font:600 12px Segoe UI;color:#FFFFFF;background:#D64545;padding:1px 8px;border-radius:9px;margin-left:6px'>" & COALESCE(_n, 0) & "</span></div>"
    & "<div style='font:12px Segoe UI;color:#5B6475;margin-bottom:4px'>Rule: more than 10% below type curve, or uptime under 92%</div>"
    & IF(COALESCE(_n, 0) = 0, "<div style='font:13px Segoe UI;color:#1B9E5A;padding:10px 0'>All wells within tolerance &#10003;</div>", _rows)
& "</div>"
```

### HTML Downtime Pareto

```dax
VAR _total = [Event Hours]
VAR _top = TOPN(5, VALUES(Downtime[Reason]), [Event Hours], DESC)
VAR _max = MAXX(_top, [Event Hours])
VAR _rows =
    CONCATENATEX(
        _top,
        VAR _h = [Event Hours]
        RETURN
        "<div style='margin:9px 0'>"
            & "<div style='display:flex;justify-content:space-between;font:13px Segoe UI;color:#14213D'><span>" & Downtime[Reason] & "</span>"
            & "<span><b>" & FORMAT(_h, "#,0") & " h</b> <span style='color:#5B6475'>(" & FORMAT(DIVIDE(_h, _total), "0%") & ")</span></span></div>"
            & "<div style='height:8px;background:#E9EDF3;border-radius:4px;margin-top:3px'><div style='width:" & FORMAT(DIVIDE(_h, _max) * 100, "0") & "%;height:8px;background:#C2410C;border-radius:4px'></div></div>"
        & "</div>",
        "",
        [Event Hours], DESC
    )
RETURN
"<div style='font-family:Segoe UI;padding:4px 8px'>"
    & "<div style='font:700 16px Segoe UI;color:#14213D'>Where the hours go</div>"
    & "<div style='font:12px Segoe UI;color:#5B6475'>Top 5 downtime reasons &middot; " & FORMAT(_total, "#,0") & " h in total</div>"
    & _rows
& "</div>"
```

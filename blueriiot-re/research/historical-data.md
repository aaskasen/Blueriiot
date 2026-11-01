# Historical data

**Status: Verified.** Route discovered in the official app's traffic, then characterized with direct read-only calls.

```
GET /prod/swimming_pool/{pool}/blue/{serial}/measures?start_date=<ISO>&end_date=<ISO>
```

## How the app uses it

On opening, the app requested the last 24 h with `start_date=2026-10-17T16:00:00.000Z`, `end_date=2026-10-18T16:00:00.000Z`. The bounds are rounded to the hour and the end is in the future. The app **double-encodes** the colon (`%253A` on the wire); the server accepts both that and plain `:`.

The walk-through of range switching (7d/30d) in the app was not completed: the app stalled at startup on the second launch while proxied (see `app-analysis.md`). Whether the app re-requests on every range change or caches is therefore **unknown**. This doesn't block the client, because ranges were characterized directly.

## Characterization (tools/probe_history.py, 2026-10-18)

| Test | Result |
|---|---|
| App-style double-encoded dates | 200, 16 points / 24 h |
| Plain ISO dates | 200, identical |
| No params | **HTTP 200 + `errorMessage`** (DynamoDB: empty key `created`) |
| Date-only (`2026-10-17`) | 200, but the end is effectively exclusive of that day: **string comparison** on `created` |
| 7 / 30 / 31 / 60 / 90 / 180 / 365-day windows | 96 / 322 / 330 / 636 / 858 / 1614 / 1678 points, all 200 |
| Single 365 d vs 30-day windows | 1678 = 1678 points; **no truncation or pagination** |
| Earliest data | **2019-08-07T09:51Z** (scan back in 180-day windows) |
| Months with no data | e.g. ~6 months ago, 24+ months ago: empty `data`, still 200 (seasonal downtime) |

## Shape

```json
{"data": [{"created": "2026-10-17T17:45:00.000Z", "blue_device_serial": "…", "swimming_pool_id": "…",
           "data": {"temperature": 10.2, "ph": 7.17, "orp": 296, "conductivity": 18, "salinity": 0,
                    "tds": 12, "fcl_computed": 0.33, "ph_mv": -6.5, "batteryMV": 3488,
                    "airtemp": 6.48, "windspeed": 5.42}}],
 "ranges": {"ph": {"min": 7.2, "max": 7.6, "ideal": 7.3}, "orp": {…}, "conductivity": {…}}}
```

- **Raw, not aggregated:** one point per device measurement, about 72 min apart (matching `wake_period` 4320 s). Larger gaps are real (device asleep, offline, winter).
- **All metrics in one point.** There is no per-metric request.
- `airtemp`/`windspeed` are missing on some points (weather merged server-side).
- `created` = measurement time. It equals `lastMeasurements[].timestamp` for the same reading.
- No ingestion timestamp, status, or per-point quality flag is exposed.
- No pagination keys (`LastEvaluatedKey` etc.) appear.

## Client behaviour

`BlueriiotClient.get_measurement_history(pool, serial, start, end)`:
- splits into 30-day windows (defensive; no cap was observed)
- normalizes to `Reading(metric, timestamp, value, unit, source="measures")`
- dedupes on (device, metric, timestamp) and clips to `[start, end)`

## Comparison against the official app

The 24-hour series the app received (capture #1) matches what the client returns for the same window: the same 16 timestamps and values (`0001.json` vs `enc:plain-iso` probe). A side-by-side check of 7d/30d **chart rendering** in the app is still open.

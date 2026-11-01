# Blueriiot Cloud API: Developer Reference

A self-contained guide for building clients against the **Blueriiot mobile-app API** (`api.riiotlabs.com/prod`). Everything here was either exercised against a real account on 2026-10-18 (**Verified**) or seen in public client source (**Source-confirmed**). Evidence and provenance are in [API_SPECIFICATION.md](API_SPECIFICATION.md) and [research/](research/).

Working implementations to copy from:
- Python: [`client/blueriiot/client.py`](client/blueriiot/client.py) (httpx + botocore)
- Swift: [`../PoolWidget/Shared/BlueriiotAPI.swift`](../PoolWidget/Shared/BlueriiotAPI.swift) and [`SigV4.swift`](../PoolWidget/Shared/SigV4.swift) (URLSession + CryptoKit, no dependencies)

> **Scope:** read-only use of your own account. State-changing routes exist (pool edits, device events) but are deliberately not documented in detail and should not be called casually.

---

## Contents

1. [Quick start](#1-quick-start)
2. [Concepts and IDs](#2-concepts-and-ids)
3. [Authentication](#3-authentication)
4. [Request conventions](#4-request-conventions)
5. [Errors](#5-errors)
6. [Endpoints](#6-endpoints)
7. [Measurement data model](#7-measurement-data-model)
8. [Ranges and status logic](#8-ranges-and-status-logic)
9. [Recipes](#9-recipes)
10. [Limits, cadence and etiquette](#10-limits-cadence-and-etiquette)
11. [Gotchas](#11-gotchas)
12. [Unknowns](#12-unknowns)

---

## 1. Quick start

```text
1. POST https://api.riiotlabs.com/prod/user/login        {"email","password"}  → temporary AWS credentials
2. GET  /prod/swimming_pool?deleted=false                 → pool id
3. GET  /prod/swimming_pool/{pool}/blue                   → device serial
4. GET  /prod/swimming_pool/{pool}/blue/{serial}/lastMeasurements?mode=blue_and_strip   → current values + ranges
5. GET  /prod/swimming_pool/{pool}/blue/{serial}/measures?start_date=…&end_date=…       → history
```

Steps 2–5 are AWS SigV4-signed (service `execute-api`, region `eu-west-1`).

```python
from blueriiot import BlueriiotClient
async with BlueriiotClient() as c:            # reads BLUERIIOT_EMAIL / BLUERIIOT_PASSWORD
    pool = (await c.get_pools())[0].swimming_pool_id
    serial = (await c.get_pool_blue_devices(pool))[0].blue_device_serial
    latest = await c.get_latest_measurement(pool, serial)
    rows = await c.get_measurement_history(pool, serial, start, end)
```

---

## 2. Concepts and IDs

| Concept | Identifier | Format | Where you get it |
|---|---|---|---|
| User | `identity_id` | `eu-west-1:<uuid>` (Cognito identity) | login response |
| Pool ("swimming pool") | `swimming_pool_id` | UUID v4 | `GET swimming_pool` |
| Device (Blue Connect) | `blue_device_serial` / `serial` | 8 hex chars, e.g. `00ABCDEF` | `GET swimming_pool/{pool}/blue` |
| Device hardware number | `SN` / `sn` | 11 digits | device payloads (not used in URLs) |
| Blue Extender (gateway) | `gateway_id` | `BLEX-<MAC>` | device payloads |

A user can have several pools, and a pool can have several devices. Measurements are addressed by **pool and device together**.

**How data gets to the cloud.** The device wakes every `wake_period` seconds (4320 s = 72 min here) and measures. Each reading reaches the cloud by one of three routes, recorded in `issuer` / `last_measure_message_*`:
- `gateway`: via the Blue Extender (Wi-Fi)
- `sigfox`: via the Sigfox radio network
- `ble`/`mobileapp`: via Bluetooth when the phone app is nearby

---

## 3. Authentication

### 3.1 Login

```http
POST /prod/user/login HTTP/1.1
Host: api.riiotlabs.com
Content-Type: application/json

{"email": "you@example.com", "password": "••••••"}
```

**200 response:**

```json
{
  "identity_id": "eu-west-1:00000000-0000-0000-0000-000000000000",
  "token": "<JWT>",
  "credentials": {
    "access_key": "ASIA…",
    "secret_key": "…",
    "session_token": "…",
    "expiration": "2026-10-18T15:53:52.000Z"
  }
}
```

| Field | Meaning |
|---|---|
| `credentials.*` | Temporary AWS credentials (Cognito identity pool). Use these to sign every other request. |
| `credentials.expiration` | ISO-8601 UTC. Observed lifetime **≈ 1 hour**. |
| `token` | Cognito OpenID token. Not needed for any route documented here. |
| `identity_id` | Your Cognito identity. Not needed in requests. |

**Failure:** 4xx on bad credentials. Treat 400/401/403 as "wrong email/password".

**Renewal:** there is **no refresh endpoint**. Log in again shortly before `expiration`; both reference clients use a 5-minute margin. Also re-login once if any request returns 401/403.

### 3.2 Signing requests (AWS Signature Version 4)

All routes except `user/login` must be signed with **SigV4**, using:

| Parameter | Value |
|---|---|
| Region | `eu-west-1` |
| Service | `execute-api` |
| Signed headers | `host;x-amz-date;x-amz-security-token` (minimum) |
| Payload hash (GET) | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (SHA-256 of empty string) |

Headers to send:

```http
Host: api.riiotlabs.com
X-Amz-Date: 20261018T123456Z
X-Amz-Security-Token: <session_token>
Authorization: AWS4-HMAC-SHA256 Credential=<access_key>/20261018/eu-west-1/execute-api/aws4_request, SignedHeaders=host;x-amz-date;x-amz-security-token, Signature=<hex>
```

**Algorithm** (any standard AWS SigV4 library works: botocore, `aws-sigv4` crates, AWS SDKs):

```text
canonical_query   = sort-by-key( uri_encode(k) "=" uri_encode(v) ) joined by "&"
                    (RFC 3986: encode everything except A–Z a–z 0–9 - . _ ~ ;  ':' → %3A)
canonical_request = "GET" \n
                    "/prod/swimming_pool/<pool>/blue/<serial>/measures" \n
                    canonical_query \n
                    "host:api.riiotlabs.com\n" "x-amz-date:<amzdate>\n" "x-amz-security-token:<token>\n" \n
                    "host;x-amz-date;x-amz-security-token" \n
                    sha256_hex("")
scope             = <yyyymmdd> "/eu-west-1/execute-api/aws4_request"
string_to_sign    = "AWS4-HMAC-SHA256" \n <amzdate> \n scope \n sha256_hex(canonical_request)
k_date    = HMAC("AWS4" + secret_key, yyyymmdd)
k_region  = HMAC(k_date, "eu-west-1")
k_service = HMAC(k_region, "execute-api")
k_signing = HMAC(k_service, "aws4_request")
signature = hex(HMAC(k_signing, string_to_sign))
```

> **The URL you send must use the same query encoding you signed.** If your HTTP library re-encodes the query after signing, the signature fails. The Swift client builds the URL from the already-encoded canonical query for this reason.

**Test vector** (from botocore, used in `PoolMonitorTests/SigV4Tests`):

```text
access_key    ASIAFAKEFAKEFAKEFAKE
secret_key    fakefakefakefakefakefakefakefakefakefake
session_token fake-session-token
time          2026-10-18T12:34:56Z
GET https://api.riiotlabs.com/prod/swimming_pool/00000000-0000-4000-8000-000000000000/blue/SERIAL01/measures?start_date=2026-10-17T00%3A00%3A00.000Z&end_date=2026-10-18T00%3A00%3A00.000Z
→ Signature=c01af9d70c5a6d30f734f44e2e9f0430a51691ea86fafe713bfa56c2c4de07aa
```

---

## 4. Request conventions

| Aspect | Convention |
|---|---|
| Base URL | `https://api.riiotlabs.com/prod/` |
| Methods | `GET` for reads; `POST` only for login |
| Trailing slash | Optional in practice: this client omits it and public clients include it (source-confirmed) |
| Response type | `application/json`, gzip-encoded when `Accept-Encoding: gzip` is sent |
| Timestamps | ISO-8601 UTC with milliseconds: `2026-10-17T17:45:00.000Z` |
| Language | Text-bearing routes take `lang=<en\|fr\|es\|de\|…>` |
| User-Agent | Not enforced. The app sends `Dart/3.6 (dart:io)`; older clients send `BlueConnect/<version>`. |
| Infrastructure | Imperva → CloudFront → API Gateway → (DynamoDB). Responses carry `x-amzn-RequestId`, `x-amz-apigw-id`. |

---

## 5. Errors

The API reports errors **three different ways**. Handle all three:

| Situation | HTTP | Body | How to detect |
|---|---|---|---|
| Bad / expired signature, wrong account | 401 / 403 | `{"message": "…"}` | status code. Re-login once, then fail. |
| Backend error with **200 status** | **200** | `{"errorMessage": "…", "errorType": "…"}` | **presence of `errorMessage`**, whatever the status |
| Gateway / transient | 429, 5xx | varies | retry with exponential backoff |

Example of the 200-with-error case (calling `measures` without dates):

```json
{"errorMessage": "One or more parameter values are not valid. The AttributeValue for a key attribute cannot contain an empty string value. Key: created"}
```

---

## 6. Endpoints

Legend: ✅ Verified on a real account · 📄 Source-confirmed only · ⚠️ state-changing (don't call)

### 6.1 `GET user` ✅

The account profile and preferences.

| Field | Type | Notes |
|---|---|---|
| `userInfo.userIdentityId` | string | Cognito identity |
| `userInfo.userId`, `email`, `firstName`, `lastName` | string | PII |
| `userInfo.region` | string | `eu` |
| `userInfo.account_type` | string | `Email` |
| `userInfo.accepted_last_eula`, `accepted_legal_terms_version`, `accepted_privacy_policy_version` | bool/int | |
| `userPreferences.display_temperature_unit` | string | `celsius` / `fahrenheit` |
| `userPreferences.display_unit_system` | string | `metric` / `imperial` |
| `userPreferences.main_swimming_pool_id` | string | default pool |
| `userPreferences.notifications.*` | object | `alerts_push_enabled`, `alerts_mail_enabled`, `measurement_frequency` (`every_week`), `measurement_day`, `measurement_hour`, … |
| `currentEula` | object | `url`, `version`, `available_languages[]` |
| `userModuleAccess` | object | feature flags: `va_config`, `autom_targets_config` |

### 6.2 `GET swimming_pool?deleted=false` ✅

All pools the user can access.

```json
{"data": [{
  "swimming_pool_id": "<uuid>", "name": "My pool", "role": "FIRST_ADMINISTRATOR",
  "created": "2019-08-07T09:47:40.223Z", "user_id": "…",
  "swimming_pool": { …full pool object, see 6.3… }
}]}
```

`role` values seen: `FIRST_ADMINISTRATOR`. The query `deleted=true` lists deleted pools (📄).

### 6.3 `GET swimming_pool/{pool}` ✅

The full pool object.

| Path | Type | Notes |
|---|---|---|
| `swimming_pool_id`, `name`, `created`, `updated`, `last_refresh_status` | | |
| `characteristics.volume` | object | `shape` (`Rectangle`…), `length`, `width`, `depth`, `depth2` (m), `capacity` (m³) |
| `characteristics.configuration` | object | `kind` (`SwimmingPool`/spa), `_type` (`Buried`…), `location` (`Outdoor`), `waterproofing` (`Liner`), `construction_year` |
| `characteristics.sanitizer` | object | `chemical` (`Chlorine`, `Salt`, `Bromine`…), `process` (`Manuel`, sic) |
| `characteristics.uv_sanitizing.activated` | bool | |
| `characteristics.filter_pump` | object | `is_present`, `operating_type` (`Manual`), `operating_hours[]` |
| `characteristics.equipment` | object | `heatings[]`, `protections[]`, `cleanings[]`, `filtrations[]` |
| `characteristics.geoloc` | object | `lat`, `lon`, `city`, `zip_code`, `country`, `country_code`, `administrative_area_level_1` (**PII**) |
| `chemistry` | object | `activeChemicalPackId`, `canSelectChemicalPack` |
| `custom_settings.measure_ranges.{temperature,ph,orp,conductivity}` | object | `min`, `max`, `ideal`, **`custom_applied`** (user overrides; only used when `custom_applied: true`) |
| `data_default.measure_ranges.{…,salinity}` | object | **default ranges** (`min`, `max`, `ideal`), e.g. pH 7.2–7.6, ORP 650–750, temp 20–40, conductivity 300–10000, salinity 2.5–3.5 g/L |
| `data_default.automation_targets.{ph,orp,temperature}` | object | `target`, `repeat_too_high`, `repeat_too_low` |
| `data_validation.measure_ranges.*` / `automation_targets.*` | object | `min`, `max`, `delta`: the allowed bounds for user edits |
| `user_access` | object | `role`, `canModifySwimmingPool`, `canDeleteSwimmingPool`, `canCreateInviteToken` |
| `strip_brand_id` | string | `generic_strips` |
| `sigfox_global_coverage` | object | `level`, `score`, `margins[]`, `redundancy`, `robustness` |

⚠️ `PUT swimming_pool/{pool}` (📄) modifies the pool. Don't call it.

### 6.4 `GET swimming_pool/{pool}/blue` ✅

The devices attached to a pool, with an embedded device summary.

```json
{"data": [{
  "blue_device_serial": "00ABCDEF", "swimming_pool_id": "<uuid>", "role": "IS_OWNER",
  "created": "2019-08-07T09:49:59.618Z", "user_id": "…",
  "blue_device": { …see table… }
}]}
```

Useful `blue_device` fields: `battery_low` (bool), `wake_period` (s), `sleep_state` (`awake`/`sleeping`), `lowPowerMode`, `fw_version_psoc`, `fw_version_history[]{fw_version_psoc,timestamp}`, `hw_generation`, `hw_type`, `hw_color`, `hw_region`, `hw_bundle_extender`, `gateway_id`, `last_measure_message` (latest reading by any route), `last_measure_message_gateway`, `last_measure_message_ble`, `last_measure_message_sigfox`, `last_measure_message_gateway_seq_number`, `measure_moments{tz_id, tz_utc_offset, moments[]}`, `sf_rc` (Sigfox radio zone), `fs_beacon_enabled`, `fs_sigfox_enabled`, `production_datetime`.

### 6.5 `GET blue/{serial}` ✅

Device detail. It overlaps 6.4 but uses different key names.

| Field | Notes |
|---|---|
| `serial`, `sn` | |
| `hw_product_name` (`Blue Connect`), `hw_product_type` (`basic`), `hw_product_pack`, `hw_generation`, `hw_sf_zone`, `hw_sf_country`, `hw_has_screw` | hardware |
| `fw_version_psoc` | firmware |
| `battery_low` (bool), `lowPowerMode` (int) | power |
| `state.sleep_state` | `awake` / … |
| `last_measure_ble`, `last_measure_sigfox` | per-route timestamps (no gateway field here; use 6.4) |
| `gateway_id` | `BLEX-<MAC>` when an Extender is paired |
| `flash_settings_to_apply.wake_period` | measurement interval (s) |
| `measure_moments.measures[]{moment_code}` | scheduled moments, e.g. `morning` |
| `contract_servicePlan` (`plus`), `contract_isBasic`, `contract_isGo`, `contract_isVpcEligible`, `contract_isSwaUs`, `contract_isMarketPlaceEligible` | subscription / plan |
| `location{location, support}` | `pool` / `none` |

### 6.6 `GET blue` ✅

All devices on the account, flattened. Returns `{"blues": [ …device summaries like 6.4… ], "upgradedCount": n, "upgradedToPlusCount": n}`. Optional `?blueProductType=` filter (📄). Each entry includes `swp_name` (the pool name).

### 6.7 `GET blue/{serial}/compatibility` ✅

`{"serial": "…", "sigfox": {"regions": [{"code": "rc1"}], "countries": [ …ISO list… ]}}`

### 6.8 `GET swimming_pool/{pool}/blue/{serial}/lastMeasurements?mode=blue_and_strip` ✅

**Current values**, one entry per metric and source, **with ranges**.

```json
{
  "status": "OK",
  "last_blue_measure_timestamp": "2026-10-18T14:14:00.000Z",
  "blue_device_serial": "00ABCDEF",
  "swimming_pool_id": "<uuid>",
  "data": [
    {"name": "temperature", "value": 9.2, "timestamp": "2026-10-18T14:14:00.000Z",
     "expired": false, "trend": "undefined", "issuer": "gateway", "priority": 10,
     "ok_min": 20, "ok_max": 40, "warning_low": 5, "warning_high": 50, "gauge_min": 0, "gauge_max": 50}
  ]
}
```

| Field | Notes |
|---|---|
| `name` | `temperature`, `ph`, `orp`, `conductivity` (seen); `salinity` and test-strip metrics such as `fcl`, `ta` (seen in public client fixtures) when available |
| `value` | number in the metric's unit (§7) |
| `timestamp` | **measurement** time |
| `expired` | `true` = stale (e.g. old strip reading). Prefer non-expired entries. |
| `issuer` | `gateway`, `sigfox`, `mobileapp`, `strip` |
| `trend` | `stable`, `increase`, `decrease`, `undefined` |
| `priority` | display order (10 = temperature, 20 = pH, 30 = ORP, 40 = conductivity) |
| `ok_min`/`ok_max`, `warning_low`/`warning_high`, `gauge_min`/`gauge_max` | ranges (§8) |

The same `name` **can appear twice** (e.g. a live `ph` from the device and an expired one from a strip). Pick non-expired first, then the newest.

📄 `GET swimming_pool/{pool}/lastMeasurements` is a pool-level variant.

### 6.9 `GET swimming_pool/{pool}/blue/{serial}/measures` ✅ (history)

**Raw history: one point per device measurement, all metrics per point.** This is the route behind the app's graphs.

| Query param | Required | Format |
|---|---|---|
| `start_date` | yes | `YYYY-MM-DDTHH:MM:SS.000Z` (UTC) |
| `end_date` | yes | same |

```json
{
  "data": [
    {"created": "2026-10-17T17:45:00.000Z", "blue_device_serial": "00ABCDEF", "swimming_pool_id": "<uuid>",
     "data": {"temperature": 10.2, "ph": 7.17, "orp": 296, "conductivity": 18, "salinity": 0,
              "tds": 12, "fcl_computed": 0.33, "ph_mv": -6.5, "batteryMV": 3488,
              "airtemp": 6.48, "windspeed": 5.42}}
  ],
  "ranges": {"ph": {"min": 7.2, "max": 7.6, "ideal": 7.3},
             "orp": {"min": 650, "max": 750, "ideal": 700},
             "conductivity": {"min": 300, "max": 10000, "ideal": 1500}}
}
```

Behaviour (all verified):

| Property | Finding |
|---|---|
| Resolution | raw, about 72 min apart; **not aggregated** |
| Order | ascending by `created` |
| Window size | **no cap observed**: a single 365-day request returned 1,678 points, identical to 30-day windowed requests |
| Pagination | none (no cursor or `LastEvaluatedKey`) |
| Depth | data back to the device's first day (2019 on the test account) |
| Bounds | compared **as strings** against `created`; inclusive. Always send full timestamps. |
| Empty range | 200 with `"data": []` |
| Missing params | **200 with `errorMessage`** (§5) |
| Encoding | plain `%3A` or the app's double-encoded `%253A` both work |
| `created` | equals `lastMeasurements[].timestamp` for the same reading, so it's the measurement time |
| Missing fields | `airtemp`/`windspeed` are absent on some points; treat every metric key as optional |
| Gaps | real (device asleep / offline / winter); don't interpolate |

The official app requests the visible range rounded to the hour, e.g. the last 24 h as `start_date=2026-10-17T16:00:00.000Z&end_date=2026-10-18T16:00:00.000Z`.

### 6.10 `GET swimming_pool/{pool}/guidance?lang=en&mode=interactive_v03` ✅

The app's current recommendation.

```json
{"guidance": {
   "swp_global_status": "SP_NOT_OK", "status": "COMPUTED", "chemicalPackId": "riiot_generic",
   "issue_to_fix": {
     "task_identifier": "ORP_LOW", "issue_title": "ORP is too low", "action_title": "Add 117 g of chlorine",
     "current_value": 307, "ideal_value": 700, "wait_duration": 180, "pool_volume": 23.36,
     "swp_range": {"ok_min": 650, "ok_max": 750, "warning_low": 400, "warning_high": 900, "ideal": 700},
     "products": [{"id": "riiot_ctx200", "display_name": "chlorine", "brand": "Generic", "quantity": 117,
                   "quantity_unit": "g", "ref_product_quantity": 50, "ref_water_quantity": 10, "ref_water_quantity_unit": "m³"}],
     "steps": [{"title": "Stop swimming", "message": "…"}], "poststeps": [], "info": [], "user_action": "Done"
   },
   "bottom_links": [], "swimming_pool_id": "<uuid>", "lang": "en"},
 "vpc_sharing": {"sharing_status": "not_shared"}}
```

`swp_global_status`: `SP_NOT_OK` seen; `SP_OK` is inferred from the automation API's status list. `task_identifier` follows `<METRIC>_<LOW|HIGH>` (`ORP_LOW`, `PH_HIGH`, …). Contains dosing advice; show it only with that context.

### 6.11 `GET swimming_pool/{pool}/guidance/history?lang=en` ✅

Past recommendations, as `{"items": [ … ], "swimming_pool_id": "…"}`. 100 items were returned; no paging parameter is known.

| Field | Notes |
|---|---|
| `task_identifier`, `task_description`, `task_action` | as in 6.10 |
| `date`, `end_date` | when the issue opened and closed |
| `end_reason` | e.g. `time_elapsed_new_measure` |
| `value_before`, `value_after` | metric value before/after |

### 6.12 `GET swimming_pool/{pool}/feed?lang=en` ✅

Short status messages: `{"data": [{"id": "SWP_NOK", "title": "Consider water treatment", "message": "…"}], "timestamp": "…", "lang": "en", "swimming_pool_id": "…"}`.

### 6.13 `GET swimming_pool/{pool}/chemistry` ✅

Chemical packs: `chemistry.activeChemicalPackId`, `canSelectChemicalPack`, `availableChemicalPacks[]` (`id`, `display_name`, `brand`, `service_plan`, `subscription_status`, `price`, `products[]`, `application.strips[]`, `translations`).

### 6.14 `GET swimming_pool/{pool}/weather?lang=en` ✅

Weather at the pool's location:

`data.timestamp`, `temperature_current`, `temperature_min`, `temperature_max` (°C), `wind_speed_current`, `wind_direction_current` (deg), `weather_current_code` / `_icon_code` / `_description` (OpenWeatherMap-style codes, e.g. `802`, `03d`), plus `weather_future_*` and `weather_future_timeframe_{one,two}_*` forecasts.

📄 `GET swimming_pool/{pool}/weather/forecast?startDate=<ISO>&lang=en` gives a longer forecast.

### 6.15 `GET swimming_pool/{pool}/status` ✅ (deprecated)

Returns the JSON string `"Please update your mobile app!"`, so it's retired. 📄 `GET swimming_pool/{pool}/status/{taskId}` is probably retired as well.

### 6.16 State-changing routes ⚠️ (documented for awareness only)

| Route | Effect |
|---|---|
| `PUT swimming_pool/{pool}` | overwrite pool settings |
| `POST blue/{serial}/releaseLastUnprocessedEvent` | device event handling |

### 6.17 The official automation API (separate)

`https://api.riiotlabs.com/automation/`, using HTTP Basic auth with email:password:
- `GET blue/{blueKey}/lastMeasurement`: `temperature_celsius`, `temperature_fahrenheit`, `ph`, `salinity_g_per_l`, `orp_mV`, `timestamp`, `blueKey`, `status[]`
- `POST blue/{blueKey}/configureWebhook`: `{"url", "active", "headers"}` pushes each new measurement

This API is documented but has **no history**.

---

## 7. Measurement data model

| Key (history) | Name in `lastMeasurements` | Unit | Kind | Notes |
|---|---|---|---|---|
| `temperature` | `temperature` | °C | measured | water temperature |
| `ph` | `ph` | pH | measured | |
| `orp` | `orp` | mV | measured | "Sanitation". Oxidation-reduction potential, **not** chlorine ppm. |
| `conductivity` | `conductivity` | µS/cm | measured | raw. **Not salinity.** |
| `salinity` | `salinity` | g/L | server-derived | from conductivity; meaningful for salt pools |
| `tds` | – | ppm (inferred) | server-derived | total dissolved solids estimate |
| `fcl_computed` | – | ppm (inferred) | server-computed | free-chlorine **estimate** from ORP/pH. Not a measurement. |
| `ph_mv` | – | mV | measured | raw pH electrode potential |
| `batteryMV` | – | mV | measured | battery voltage (~3490 mV with `battery_low: true` observed) |
| `airtemp` | – | °C | weather | merged in server-side; optional |
| `windspeed` | – | unknown (m/s?) | weather | optional |

Strip metrics (via `mode=blue_and_strip`, from manual test strips) were not present on the test account. Public fixtures show `fcl` and `ta`; the automation API's status codes suggest `fbr`, `cya` and `th` too (**inferred**).

---

## 8. Ranges and status logic

Every metric in `lastMeasurements` carries six bounds:

```
gauge_min ── warning_low ── ok_min ══ GOOD ══ ok_max ── warning_high ── gauge_max
   BAD          WARNING                          WARNING        BAD
```

| Value | Status (as the official app colours it) |
|---|---|
| `ok_min ≤ v ≤ ok_max` | **Good** (blue) |
| `warning_low ≤ v < ok_min` or `ok_max < v ≤ warning_high` | **Warning** (orange) |
| `v < warning_low` or `v > warning_high` | **Bad** (red) |

Sources of the ranges: on the test account (`custom_applied: false` everywhere), `lastMeasurements` used `data_default.measure_ranges`. That custom ranges replace them when `custom_applied` is true is an **inference** (untested). `measures.ranges` returns only `min`/`max`/`ideal` for pH, ORP and conductivity. Use `lastMeasurements` for full bounds.

---

## 9. Recipes

**Latest reading per metric**

```python
lm = await c.get_latest_measurement(pool, serial)
for name in ("temperature", "ph", "orp", "conductivity"):
    m = lm.best(name)          # non-expired first, then newest
    print(name, m.value, m.unit, m.timestamp, m.ok_min, m.ok_max)
```

**30 days of history → CSV**

```bash
.venv/bin/python examples/export_history.py --days 30
```

**Full history since the device was installed**

```python
rows = await c.get_measurement_history(pool, serial, datetime(2019, 1, 1, tzinfo=UTC), datetime.now(UTC))
# client splits into 30-day windows, dedupes on (device, metric, created), clips to [start, end)
```

**Incremental sync** (cheap polling): store the max `created` you've seen, then request `start_date = last_created + 1 ms`, `end_date = now` every ≥ 30 min. Dedupe on `created`.

**"Is the data fresh?"** Compare `last_blue_measure_timestamp` (measurement time) with now. More than about 3 × `wake_period` old means the device or Extender is likely offline. Don't use your fetch time.

---

## 10. Limits, cadence and etiquette

- **No documented or observed rate limit.** Be conservative anyway: ≤ 1 request/s, exponential backoff on 429/5xx.
- New data arrives about every 72 min (`wake_period`). **Polling more often than every 15–30 min gains nothing.**
- Cache login credentials for their lifetime (≈ 1 h); don't log in per request.
- Use the official automation API's webhook if you need push-style updates.

---

## 11. Gotchas

1. **Errors can come back as HTTP 200**: check for `errorMessage`.
2. **Date bounds are string comparisons.** `2026-10-17` ≠ `2026-10-17T00:00:00.000Z`. Always send full UTC timestamps with milliseconds.
3. **Sign exactly what you send**: query encoding must match byte for byte.
4. **Duplicate metric names** in `lastMeasurements` (device versus strip, `expired`).
5. **Conductivity ≠ salinity.** Keep them separate.
6. **`fcl_computed` and `tds` are estimates**, not sensor readings.
7. **Optional keys** in history points (`airtemp`, `windspeed`).
8. `blue/{serial}` and `swimming_pool/{pool}/blue` name the same timestamps differently (`last_measure_ble` vs `last_measure_message_ble`).
9. `characteristics.sanitizer.process` uses the spelling `Manuel`.
10. `status` is deprecated and returns a bare string.

---

## 12. Unknowns

- Whether `measures` depth or availability depends on a Premium plan. Only a `plus` account was tested.
- Paging for `guidance/history` beyond 100 items.
- `windspeed` unit; exact definitions of `tds` and `fcl_computed`.
- Whether the app re-requests `measures` on every range change or caches.

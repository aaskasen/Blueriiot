# Blueriiot Cloud API — Endpoint Catalogue

Investigation date: **2026-10-18**. For a developer-oriented guide with full schemas see **[API_REFERENCE.md](API_REFERENCE.md)**. Account: owner's own (Blue Connect Plus, gen 2, via Blue Extender, plan `plus`).
App observed: Blueriiot iOS 4.18.0 (`com.riiotlabs.blue`, Flutter, `Dart/3.6 (dart:io)` user agent) running on Apple-Silicon macOS.

**Confidence levels**
- **Verified** — reproduced with the Python client against the owner's account and/or observed in the official app's traffic.
- **Source-confirmed** — present in public client code, not independently exercised here.
- **Hypothesis** — untested.

## Two APIs

| | Mobile-app API (this catalogue) | Official automation API |
|---|---|---|
| Base | `https://api.riiotlabs.com/prod/` | `https://api.riiotlabs.com/automation/` |
| Auth | `POST user/login` → temp AWS creds → SigV4 | HTTP Basic (email:password) |
| Scope | pools, devices, latest, **history**, guidance, feed… | `GET blue/{blueKey}/lastMeasurement`, `POST …/configureWebhook` only |
| Source | community clients + app traffic | RiiotLabs/Blue-backend-automation@9946c11 `README.md` |

The automation API has no history route. Everything below is the mobile-app API.

## Common behaviour

- **Auth:** see [research/authentication.md](research/authentication.md). All routes except `user/login` require SigV4 (`execute-api`, `eu-west-1`) with `X-Amz-Security-Token`.
- **Errors:** the backend can return **HTTP 200 with `{"errorMessage": …}`** (seen for `measures` with missing params). Treat `errorMessage` as an error regardless of status (same rule as MBW.Client.BlueRiiotApi@44cbd44 `BlueClient.cs:92`).
- **Infra:** API Gateway behind CloudFront, fronted by Imperva (`x-amz-apigw-id`, `X-Cache: Miss from cloudfront`, gzip). Data appears to come from DynamoDB (error text names attribute `created`).
- **Rate limits:** none documented or observed. The client throttles to ≥1 request/s, with retry/backoff on 429/5xx. The device measures about every 72 min (automation README line 45; `flash_settings_to_apply.wake_period = 4320` s), so polling more often gains nothing.
- **IDs:** `{pool}` = `swimming_pool_id` (UUID); `{serial}` = `blue_device_serial` (8 hex chars).

## Endpoint ledger

| # | Method & route | Params | Response (top level) | Confidence | Evidence |
|---|---|---|---|---|---|
| 1 | `POST user/login` | JSON `{email, password}` | `identity_id`, `token`, `credentials{access_key, secret_key, session_token, expiration}` | **Verified** | probe 2026-10-18; homebridge-blueconnect@0e34bcc `blueriiot-api.js:33`; MBW `BlueClient.cs:112` |
| 2 | `GET user` | – | `userInfo`, `userPreferences`, `currentEula`, `userModuleAccess` | **Verified** | probe; app capture #3; MBW `BlueClient.cs:131` |
| 3 | `GET blue` | (`blueProductType` optional) | `blues[]` (device summary incl. `battery_low`, `gateway_id`, `contract_servicePlan`), `upgradedCount`, `upgradedToPlusCount` | **Verified** | probe; MBW `BlueClient.cs:137` |
| 4 | `GET swimming_pool` | `deleted=false` | `data[]{swimming_pool_id, role, swimming_pool{name,…}}` | **Verified** | probe; MBW `BlueClient.cs:164` |
| 5 | `GET swimming_pool/{pool}` | – | pool characteristics | **Verified** | probe; MBW `BlueClient.cs:169` |
| 6 | `GET swimming_pool/{pool}/blue` | – | `data[]{blue_device_serial, …}` | **Verified** | probe; MBW `BlueClient.cs:199` |
| 7 | `GET blue/{serial}` | – | device detail: `fw_version_psoc`, `hw_*`, `battery_low`, `lowPowerMode`, `state.sleep_state`, `gateway_id` (`BLEX-<MAC>` = Extender), `last_measure_ble`, `last_measure_sigfox`, `measure_moments`, `flash_settings_to_apply.wake_period`, `contract_*` | **Verified** | probe; MBW `BlueClient.cs:144` |
| 8 | `GET blue/{serial}/compatibility` | – | `sigfox{regions[], countries[]}` | **Verified** | probe; MBW `BlueClient.cs:159` |
| 9 | `GET swimming_pool/{pool}/blue/{serial}/lastMeasurements` | `mode=blue_and_strip` | `status`, `last_blue_measure_timestamp`, `data[]{name, value, timestamp, expired, trend, issuer, ok_min/max, warning_low/high, gauge_min/max, priority}` | **Verified** | probe; MBW `BlueClient.cs:149` |
| 10 | **`GET swimming_pool/{pool}/blue/{serial}/measures`** | `start_date`, `end_date` (ISO-8601 UTC, ms) | `data[]{created, blue_device_serial, swimming_pool_id, data{temperature, ph, orp, conductivity, salinity, tds, fcl_computed, ph_mv, batteryMV, airtemp?, windspeed?}}`, `ranges{ph,orp,conductivity:{min,max,ideal}}` | **Verified** | app capture #1–2 (`captures/sanitized/flows/0001.json`); `tools/probe_history.py` → `captures/sanitized/history_probe.json` |
| 11 | `GET swimming_pool/{pool}/status` | – | JSON string `"Please update your mobile app!"`: **deprecated** | **Verified** (200) | probe; MBW `BlueClient.cs:189` |
| 12 | `GET swimming_pool/{pool}/feed` | `lang` | `data[]{id, title, message}`, `timestamp` | **Verified** | probe; MBW `BlueClient.cs:179` |
| 13 | `GET swimming_pool/{pool}/guidance` | `lang`, `mode=interactive_v03` | `guidance{swp_global_status, issue_to_fix{task_identifier, current_value, ideal_value, action_title, …}}`, `vpc_sharing` | **Verified** | probe; MBW `BlueClient.cs:209` |
| 14 | `GET swimming_pool/{pool}/guidance/history` | `lang` | `items[]{task_identifier, date, end_date, end_reason, value_before, value_after, task_action}` (100 items returned) | **Verified** | probe; MBW `BlueClient.cs:214` |
| 15 | `GET swimming_pool/{pool}/chemistry` | – | `chemistry{activeChemicalPackId, availableChemicalPacks[], canSelectChemicalPack}` | **Verified** | probe; MBW `BlueClient.cs:204` |
| 16 | `GET swimming_pool/{pool}/weather` | `lang` | weather for pool location | **Verified** (200) | probe; MBW `BlueClient.cs:219` |
| 17 | `GET swimming_pool/{pool}/weather/forecast` | `startDate`, `lang` | forecast | Source-confirmed | MBW `BlueClient.cs:224` |
| 18 | `GET swimming_pool/{pool}/lastMeasurements` | – | pool-level latest | Source-confirmed | MBW `BlueClient.cs:184` |
| 19 | `GET swimming_pool/{pool}/status/{taskId}` | – | task status | Source-confirmed | MBW `BlueClient.cs:194` |
| — | `PUT swimming_pool/{pool}`, `POST blue/{serial}/releaseLastUnprocessedEvent` | | **state-changing — deliberately not implemented or called** | Source-confirmed | MBW `BlueClient.cs:154,174` |

## `measures` (history) details

See [research/historical-data.md](research/historical-data.md). In brief:

- One point per device measurement (about every 72 min). **Every metric is returned together in each point.**
- **No window cap observed:** a single 365-day call returned 1,678 points, identical to the 30-day-windowed fetch.
- **Earliest data on this account: 2019-08-07T09:51Z.**
- Bounds are compared **as strings** against `created`. Always send the full `YYYY-MM-DDTHH:MM:SS.000Z`.
- Missing params → HTTP 200 + `errorMessage` (DynamoDB "AttributeValue … cannot contain an empty string … Key: created").
- `created` equals the `timestamp` of the same reading in `lastMeasurements` (14:14:00Z in both), so it is the **measurement time**, not ingestion time.

## Units

| Field | Unit | Note |
|---|---|---|
| temperature | °C | |
| ph | pH | |
| orp | mV | "sanitation". Not free chlorine. |
| conductivity | µS/cm | raw sensor value; **not salinity** |
| salinity | g/L | separate server-derived field |
| tds | ppm (inferred) | server-derived |
| fcl_computed | ppm (inferred) | server estimate; not a measurement |
| ph_mv | mV | raw electrode potential |
| batteryMV | mV | battery voltage |
| airtemp, windspeed | °C / unknown | weather merged in by server |

# Findings

## Verified

1. Login → temporary Cognito AWS credentials (~1 h) → SigV4 (`execute-api`, `eu-west-1`).
2. Device discovery, latest readings, device/battery/Extender status, guidance, guidance history, feed, chemistry and weather all return 200 on the owner's account.
3. **History:** `GET swimming_pool/{pool}/blue/{serial}/measures?start_date&end_date`. Raw points about every 72 min, all metrics per point, no observed window cap, data back to 2019-08-07.
4. A 30-day CSV export of temperature, pH, ORP and conductivity works (322 points; `exports/history_20260918_20261018.csv`).
5. No certificate pinning in app 4.18.0.

## Device observations

Device-specific readings (battery state, water values, connection routes) were checked against the owner's account. They're intentionally left out of this public write-up. The generic behaviour they revealed is documented in `../API_REFERENCE.md` (e.g. `issuer: gateway` for Extender-delivered readings, and `battery_low` alongside `batteryMV`).

## Open questions

- Does the app re-request `measures` on range change, or cache? (UI walk-through not completed.)
- Premium gating of `measures` depth (needs a non-Premium account; out of scope).
- `windspeed` unit; exact semantics of `tds` / `fcl_computed`.

## Blockers hit

- The app stalled at startup while proxied (likely Firebase HTTP/3 realtime stream). The workaround is `--allow-hosts`; see `app-analysis.md`.

# blueriiot-re

Read-only Python client, history export and dashboard for the owner's Blueriiot Blue Connect Plus. Built on an evidence-backed spec of the Blueriiot mobile-app cloud API.

- **[API_REFERENCE.md](API_REFERENCE.md)** — developer guide: auth/signing, every endpoint with full schemas, errors, recipes
- **[API_SPECIFICATION.md](API_SPECIFICATION.md)** — endpoint catalogue with evidence and confidence
- **[research/](research/)** — authentication, historical data, Premium, app analysis, findings

## Setup

```bash
/opt/homebrew/bin/python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp .env.example .env   # fill in BLUERIIOT_EMAIL / BLUERIIOT_PASSWORD
```

## Use

```bash
.venv/bin/python examples/probe_account.py            # discover devices, latest readings, save sanitized fixtures
.venv/bin/python examples/export_history.py --days 30 # CSV of temperature/pH/ORP/conductivity
.venv/bin/python examples/export_history.py --start 2026-07-01 --end 2026-08-01 --all-metrics
.venv/bin/uvicorn dashboard.app:app --port 8765       # http://127.0.0.1:8765
.venv/bin/pytest                                      # unit tests (no network)
```

```python
from blueriiot import BlueriiotClient

async with BlueriiotClient() as c:
    await c.login()                                    # or reads .env vars lazily
    pool = (await c.get_pools())[0].swimming_pool_id
    serial = (await c.get_pool_blue_devices(pool))[0].blue_device_serial
    latest = await c.get_latest_measurement(pool, serial)
    rows = await c.get_measurement_history(pool, serial, start, end)
```

## Guarantees

- GET-only, apart from the login POST. No settings, calibration, firmware or schedule changes.
- Credentials are server-side only (`.env`). Tokens stay in memory. Saved fixtures are redacted.
- At most 1 request/s by default, with exponential backoff on 429/5xx.
- `conductivity` (µS/cm) and `salinity` (g/L) are kept as separate metrics.

## Layout

```
client/blueriiot/   client.py auth.py models.py history.py store.py redact.py
tests/              unit tests + synthetic fixtures
examples/           probe_account.py, export_history.py
tools/              capture_addon.py (mitmproxy), probe_history.py
dashboard/          FastAPI + Chart.js
captures/sanitized/ redacted evidence (captures/raw is git-ignored)
```

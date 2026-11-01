"""Read-only live probe of the owner's account.

    .venv/bin/python examples/probe_account.py

Reads BLUERIIOT_EMAIL / BLUERIIOT_PASSWORD from .env. Performs only GETs
(plus the login POST). Writes:
  captures/raw/<name>.json          unsanitized (git-ignored)
  captures/sanitized/<name>.json    redacted, safe to share
  data/readings.sqlite              local accumulator
  exports/latest.csv
"""

from __future__ import annotations

import asyncio
import json
import logging
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "client"))

from blueriiot import ApiError, BlueriiotClient, ReadingStore, write_csv  # noqa: E402
from blueriiot.redact import redact  # noqa: E402

RAW, SAN = ROOT / "captures/raw", ROOT / "captures/sanitized"


def save(name: str, data, ids: set[str]) -> None:
    RAW.mkdir(parents=True, exist_ok=True)
    SAN.mkdir(parents=True, exist_ok=True)
    (RAW / f"{name}.json").write_text(json.dumps(data, indent=2, ensure_ascii=False))
    (SAN / f"{name}.json").write_text(json.dumps(redact(data, ids), indent=2, ensure_ascii=False))


async def main() -> None:
    load_dotenv(ROOT / ".env")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)  # its INFO line prints unredacted URLs
    (ROOT / "data").mkdir(exist_ok=True)
    store = ReadingStore(ROOT / "data/readings.sqlite")
    ids: set[str] = set()
    results: dict[str, str] = {}

    async with BlueriiotClient(min_interval=1.5) as c:
        await c.login()
        print("login OK; credentials expire", c._session.expiration.isoformat())

        async def attempt(name, coro):
            try:
                data = await coro
                save(name, data, ids)
                results[name] = "200"
                return data
            except ApiError as e:
                results[name] = f"{e.status} {e.message[:80]}"
                return None

        user = await attempt("user", c.get_user())
        if user:
            ids.update(str(v) for k, v in user.items() if k.endswith("_id") and isinstance(v, str))
        await attempt("blue_list", c.get_blues())
        pools = await c.get_pools()
        ids.update(p.swimming_pool_id for p in pools)
        save("swimming_pools", {"data": [p.model_dump() for p in pools]}, ids)
        for i, pool in enumerate(pools):
            pid = pool.swimming_pool_id
            devs = await c.get_pool_blue_devices(pid)
            ids.update(d.blue_device_serial for d in devs)
            save(f"pool{i}_blue_devices", {"data": [d.model_dump() for d in devs]}, ids)
            for name, coro in [
                (f"pool{i}", c.get_pool(pid)),
                (f"pool{i}_status", c.get_pool_status(pid)),
                (f"pool{i}_feed", c.get_feed(pid)),
                (f"pool{i}_guidance", c.get_guidance(pid)),
                (f"pool{i}_guidance_history", c.get_guidance_history(pid)),
                (f"pool{i}_chemistry", c.get_chemistry(pid)),
                (f"pool{i}_weather", c.get_weather(pid)),
            ]:
                await attempt(name, coro)
            for j, d in enumerate(devs):
                s = d.blue_device_serial
                await attempt(f"pool{i}_dev{j}_device", c.get_blue_device(s))
                await attempt(f"pool{i}_dev{j}_compatibility", c.get_blue_compatibility(s))
                raw = await attempt(f"pool{i}_dev{j}_lastMeasurements", c.get_last_measurements_raw(pid, s))
                if raw:
                    rows = await c.snapshot_readings(pid, s)
                    print(f"device {j}: {store.add(rows)} new readings stored")
                    for r in rows:
                        print(f"   {r.metric:13s} {r.value:>8} {r.unit or '':6s} @ {r.timestamp.isoformat()} ({r.issuer})")

    now = datetime.now(timezone.utc)
    (ROOT / "exports").mkdir(exist_ok=True)
    n = write_csv(store.query(None, now - timedelta(days=3650), now + timedelta(days=1)), ROOT / "exports/latest.csv")
    print(f"\nexported {n} rows -> exports/latest.csv")
    print("\nendpoint results:")
    for k, v in results.items():
        print(f"  {k:40s} {v}")


if __name__ == "__main__":
    asyncio.run(main())

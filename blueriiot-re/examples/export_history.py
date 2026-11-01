"""Export measurement history to CSV (read-only).

    .venv/bin/python examples/export_history.py            # last 30 days
    .venv/bin/python examples/export_history.py --days 365
    .venv/bin/python examples/export_history.py --start 2026-07-01 --end 2026-08-01

Writes exports/history_<start>_<end>.csv and stores rows in data/readings.sqlite.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "client"))
from blueriiot import CORE_METRICS, BlueriiotClient, ReadingStore, write_csv  # noqa: E402

UTC = timezone.utc


def parse_day(s: str) -> datetime:
    return datetime.fromisoformat(s).replace(tzinfo=UTC)


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--start", type=parse_day)
    ap.add_argument("--end", type=parse_day)
    ap.add_argument("--all-metrics", action="store_true",
                    help="also export tds, fcl_computed, ph_mv, batteryMV, airtemp, windspeed, salinity")
    args = ap.parse_args()
    load_dotenv(ROOT / ".env")
    logging.basicConfig(level=logging.WARNING)

    end = args.end or datetime.now(UTC)
    start = args.start or end - timedelta(days=args.days)

    async with BlueriiotClient(min_interval=1.5) as c:
        pool = (await c.get_pools())[0].swimming_pool_id
        serial = (await c.get_pool_blue_devices(pool))[0].blue_device_serial
        rows = await c.get_measurement_history(pool, serial, start, end)

    if not args.all_metrics:
        rows = [r for r in rows if r.metric in CORE_METRICS]
    (ROOT / "data").mkdir(exist_ok=True)
    store = ReadingStore(ROOT / "data/readings.sqlite")
    added = store.add(rows)
    (ROOT / "exports").mkdir(exist_ok=True)
    out = ROOT / f"exports/history_{start:%Y%m%d}_{end:%Y%m%d}.csv"
    write_csv(rows, out)

    print(f"{start:%Y-%m-%d %H:%M} -> {end:%Y-%m-%d %H:%M} UTC: {len(rows)} rows ({added} new in local db)")
    print(f"wrote {out.relative_to(ROOT)}")
    stamps = sorted({r.timestamp for r in rows})
    if stamps:
        gaps = [(a, b) for a, b in zip(stamps, stamps[1:]) if b - a > timedelta(hours=3)]
        print(f"{len(stamps)} measurement times, first {stamps[0]:%Y-%m-%d %H:%M}, last {stamps[-1]:%Y-%m-%d %H:%M}; "
              f"{len(gaps)} gaps > 3h")
    for metric, n in sorted(Counter(r.metric for r in rows).items()):
        vals = [r.value for r in rows if r.metric == metric]
        print(f"  {metric:13s} n={n:<5} min={min(vals):<8g} max={max(vals):<8g} unit={next(r.unit for r in rows if r.metric == metric)}")


if __name__ == "__main__":
    asyncio.run(main())

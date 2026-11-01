"""Read-only characterization of the `measures` history endpoint.

    .venv/bin/python tools/probe_history.py

Tests date encodings, window lengths, and how far back data goes.
Writes a summary to captures/sanitized/history_probe.json (no raw values of IDs).
"""

from __future__ import annotations

import asyncio
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "client"))
from blueriiot import ApiError, BlueriiotClient  # noqa: E402

UTC = timezone.utc


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def summarize(payload) -> dict:
    pts = payload.get("data", []) if isinstance(payload, dict) else []
    created = sorted(p.get("created") for p in pts if p.get("created"))
    return {"n": len(pts), "first": created[0] if created else None, "last": created[-1] if created else None,
            "top_keys": sorted(payload) if isinstance(payload, dict) else None}


async def main() -> None:
    load_dotenv(ROOT / ".env")
    out: dict = {"run_at": datetime.now(UTC).isoformat(), "tests": []}
    async with BlueriiotClient(min_interval=1.5) as c:
        pool = (await c.get_pools())[0].swimming_pool_id
        serial = (await c.get_pool_blue_devices(pool))[0].blue_device_serial
        path = f"swimming_pool/{pool}/blue/{serial}/measures"
        now = datetime.now(UTC).replace(minute=0, second=0, microsecond=0)

        async def t(label, params):
            try:
                res = {"label": label, "status": 200, **summarize(await c.get_json(path, params))}
            except ApiError as e:
                res = {"label": label, "status": e.status, "error": e.message[:160]}
            out["tests"].append(res)
            print(json.dumps(res))

        day = (now - timedelta(days=1), now)
        # 1. Encodings: app style (pre-encoded ':' -> %253A on the wire) vs plain ISO
        await t("enc:app-double", {"start_date": iso(day[0]).replace(":", "%3A"),
                                   "end_date": iso(day[1]).replace(":", "%3A")})
        await t("enc:plain-iso", {"start_date": iso(day[0]), "end_date": iso(day[1])})
        await t("enc:no-params", {})
        await t("enc:date-only", {"start_date": day[0].strftime("%Y-%m-%d"), "end_date": day[1].strftime("%Y-%m-%d")})
        # 2. Window lengths ending now
        for d in (7, 30, 31, 60, 90, 180, 365):
            await t(f"window:{d}d", {"start_date": iso(now - timedelta(days=d)), "end_date": iso(now)})
        # 3. Depth: 7-day windows far back
        for months in (3, 6, 12, 24, 36, 60, 96):
            end = now - timedelta(days=30 * months)
            await t(f"depth:{months}mo-ago-7d", {"start_date": iso(end - timedelta(days=7)), "end_date": iso(end)})

    (ROOT / "captures/sanitized/history_probe.json").write_text(json.dumps(out, indent=2))


if __name__ == "__main__":
    asyncio.run(main())

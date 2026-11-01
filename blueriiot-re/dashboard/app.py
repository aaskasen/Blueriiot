"""Minimal pool dashboard. Credentials stay server-side (.env); the browser
only receives readings.

    .venv/bin/uvicorn dashboard.app:app --port 8765
    open http://127.0.0.1:8765
"""

from __future__ import annotations

import io
import sys
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse, StreamingResponse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "client"))
from blueriiot import CORE_METRICS, BlueriiotClient, BlueriiotError, ReadingStore, write_csv  # noqa: E402

UTC = timezone.utc
RANGES = {"24h": timedelta(hours=24), "7d": timedelta(days=7), "30d": timedelta(days=30),
          "90d": timedelta(days=90), "365d": timedelta(days=365)}
LATEST_TTL = 300  # seconds; the device only measures ~every 72 min

state: dict = {}


@asynccontextmanager
async def lifespan(_: FastAPI):
    load_dotenv(ROOT / ".env")
    (ROOT / "data").mkdir(exist_ok=True)
    state["client"] = BlueriiotClient(min_interval=1.0)
    state["store"] = ReadingStore(ROOT / "data/readings.sqlite")
    state["cache"] = {}
    yield
    await state["client"].aclose()
    state["store"].close()


app = FastAPI(title="Blueriiot dashboard", lifespan=lifespan)


async def _device() -> tuple[str, str, str]:
    if "device" not in state:
        c: BlueriiotClient = state["client"]
        pool = (await c.get_pools())[0]
        dev = (await c.get_pool_blue_devices(pool.swimming_pool_id))[0]
        state["device"] = (pool.swimming_pool_id, dev.blue_device_serial, pool.display_name)
    return state["device"]


def _window(range_: str | None, start: str | None, end: str | None) -> tuple[datetime, datetime]:
    if start:
        s = datetime.fromisoformat(start).replace(tzinfo=UTC)
        e = datetime.fromisoformat(end).replace(tzinfo=UTC) + timedelta(days=1) if end else datetime.now(UTC)
        if e <= s:
            raise HTTPException(400, "end must be after start")
        return s, e
    if range_ not in RANGES:
        raise HTTPException(400, f"range must be one of {list(RANGES)}")
    e = datetime.now(UTC)
    return e - RANGES[range_], e


@app.get("/")
async def index():
    return FileResponse(ROOT / "dashboard/index.html")


@app.get("/api/latest")
async def latest():
    cached = state["cache"].get("latest")
    if cached and time.time() - cached[0] < LATEST_TTL:
        return cached[1]
    try:
        pool_id, serial, pool_name = await _device()
        c: BlueriiotClient = state["client"]
        lm = await c.get_latest_measurement(pool_id, serial)
        dev = await c.get_blue_device(serial)
    except BlueriiotError as e:
        raise HTTPException(502, str(e)) from e
    metrics = {}
    for name in CORE_METRICS:
        m = lm.best(name)
        if m:
            metrics[name] = {"value": m.value, "unit": m.unit, "timestamp": m.timestamp, "trend": m.trend,
                             "ok_min": m.ok_min, "ok_max": m.ok_max, "issuer": m.issuer}
    result = {
        "pool_name": pool_name,
        "last_measure": lm.last_blue_measure_timestamp,
        "metrics": metrics,
        "device": {"battery_low": dev.get("battery_low"), "sleep_state": (dev.get("state") or {}).get("sleep_state"),
                   "service_plan": dev.get("contract_servicePlan"), "firmware": dev.get("fw_version_psoc"),
                   "via_extender": str(dev.get("gateway_id", "")).startswith("BLEX"),
                   "last_measure_ble": dev.get("last_measure_ble")},
    }
    state["cache"]["latest"] = (time.time(), result)
    return result


async def _history(start: datetime, end: datetime):
    pool_id, serial, _ = await _device()
    try:
        rows = await state["client"].get_measurement_history(pool_id, serial, start, end)
    except BlueriiotError as e:
        raise HTTPException(502, str(e)) from e
    rows = [r for r in rows if r.metric in CORE_METRICS]
    state["store"].add(rows)
    return rows


@app.get("/api/history")
async def history(range: str | None = Query("7d"), start: str | None = None, end: str | None = None):
    s, e = _window(range, start, end)
    rows = await _history(s, e)
    series: dict[str, list] = {m: [] for m in CORE_METRICS}
    for r in rows:
        series[r.metric].append([r.timestamp.isoformat(), r.value])
    return {"start": s, "end": e, "count": len({r.timestamp for r in rows}), "series": series}


@app.get("/api/history.csv")
async def history_csv(range: str | None = Query("7d"), start: str | None = None, end: str | None = None):
    s, e = _window(range, start, end)
    rows = await _history(s, e)
    buf = io.StringIO()
    write_csv(rows, buf)
    name = f"pool_{s:%Y%m%d}_{e:%Y%m%d}.csv"
    return StreamingResponse(iter([buf.getvalue()]), media_type="text/csv",
                             headers={"Content-Disposition": f'attachment; filename="{name}"'})

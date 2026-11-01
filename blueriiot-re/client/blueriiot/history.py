"""Date-window splitting, normalization and de-duplication for history reads.

The server-side history route is NOT yet confirmed (see research/historical-data.md).
These helpers are endpoint-agnostic so they can wrap whatever route the
traffic capture reveals, and they also back the local SQLite accumulator.
"""

from __future__ import annotations

from collections.abc import Iterable, Iterator
from datetime import datetime, timedelta, timezone

from .models import UNITS, Reading


def ensure_utc(dt: datetime) -> datetime:
    return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt.astimezone(timezone.utc)


def split_windows(start: datetime, end: datetime, max_window: timedelta) -> Iterator[tuple[datetime, datetime]]:
    """Yield contiguous [a, b) windows covering [start, end), each <= max_window."""
    start, end = ensure_utc(start), ensure_utc(end)
    if end <= start:
        raise ValueError("end must be after start")
    if max_window <= timedelta(0):
        raise ValueError("max_window must be positive")
    a = start
    while a < end:
        b = min(a + max_window, end)
        yield a, b
        a = b


def dedupe(readings: Iterable[Reading]) -> list[Reading]:
    """Drop duplicates on (device, metric, timestamp); keep first seen; sort by time."""
    seen: dict[tuple[str, str, datetime], Reading] = {}
    for r in readings:
        key = (r.device_serial, r.metric, ensure_utc(r.timestamp))
        seen.setdefault(key, r)
    return sorted(seen.values(), key=lambda r: (r.timestamp, r.metric))


def readings_from_measures(payload: dict, device_serial: str) -> list[Reading]:
    """Normalize a `measures` history payload: one point per `created`, many metrics each."""
    out: list[Reading] = []
    for point in payload.get("data", []) or []:
        created = point.get("created")
        if not created:
            continue
        ts = ensure_utc(datetime.fromisoformat(created.replace("Z", "+00:00")))
        for metric, value in (point.get("data") or {}).items():
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                continue
            out.append(Reading(device_serial=device_serial, metric=metric, timestamp=ts,
                               value=float(value), unit=UNITS.get(metric), source="measures"))
    return out


def readings_from_last_measurements(payload: dict, device_serial: str,
                                    include_expired: bool = False) -> list[Reading]:
    """Normalize a lastMeasurements payload into Reading rows."""
    out: list[Reading] = []
    for m in payload.get("data", []) or []:
        if m.get("value") is None or not m.get("timestamp"):
            continue
        if m.get("expired") and not include_expired:
            continue
        out.append(Reading(
            device_serial=device_serial,
            metric=m["name"],
            timestamp=ensure_utc(datetime.fromisoformat(m["timestamp"].replace("Z", "+00:00"))),
            value=float(m["value"]),
            unit=UNITS.get(m["name"]),
            issuer=m.get("issuer"),
            source="lastMeasurements",
        ))
    return out

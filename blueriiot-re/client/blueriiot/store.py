"""Local SQLite accumulator for readings + CSV export.

Independent of any server history route: polling lastMeasurements at a
conservative interval (the device measures roughly every 72 min per the
official automation API README) builds a local history from now on.
"""

from __future__ import annotations

import csv
import sqlite3
from collections.abc import Iterable
from datetime import datetime
from pathlib import Path

from .history import ensure_utc
from .models import Reading

SCHEMA = """
CREATE TABLE IF NOT EXISTS readings (
  device_serial TEXT NOT NULL,
  metric        TEXT NOT NULL,
  ts            TEXT NOT NULL,   -- ISO-8601 UTC measurement timestamp
  value         REAL NOT NULL,
  unit          TEXT,
  issuer        TEXT,
  source        TEXT,
  fetched_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (device_serial, metric, ts)
);
"""

CSV_FIELDS = ["timestamp_utc", "device_serial", "metric", "value", "unit", "issuer", "source"]


class ReadingStore:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.db = sqlite3.connect(self.path)
        self.db.executescript(SCHEMA)

    def close(self) -> None:
        self.db.close()

    def add(self, readings: Iterable[Reading]) -> int:
        cur = self.db.executemany(
            "INSERT OR IGNORE INTO readings(device_serial, metric, ts, value, unit, issuer, source)"
            " VALUES (?,?,?,?,?,?,?)",
            [(r.device_serial, r.metric, ensure_utc(r.timestamp).isoformat(), r.value, r.unit,
              r.issuer, r.source) for r in readings])
        self.db.commit()
        return cur.rowcount

    def query(self, device_serial: str | None, start: datetime, end: datetime,
              metrics: Iterable[str] | None = None) -> list[Reading]:
        sql = "SELECT device_serial, metric, ts, value, unit, issuer, source FROM readings WHERE ts >= ? AND ts < ?"
        args: list = [ensure_utc(start).isoformat(), ensure_utc(end).isoformat()]
        if device_serial:
            sql += " AND device_serial = ?"
            args.append(device_serial)
        metrics = list(metrics or [])
        if metrics:
            sql += f" AND metric IN ({','.join('?' * len(metrics))})"
            args += metrics
        sql += " ORDER BY ts, metric"
        return [Reading(device_serial=d, metric=m, timestamp=datetime.fromisoformat(t), value=v,
                        unit=u, issuer=i, source=s or "unknown")
                for d, m, t, v, u, i, s in self.db.execute(sql, args)]


def write_csv(readings: Iterable[Reading], path_or_file) -> int:
    own = isinstance(path_or_file, (str, Path))
    f = open(path_or_file, "w", newline="", encoding="utf-8") if own else path_or_file
    try:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        n = 0
        for r in readings:
            w.writerow({"timestamp_utc": ensure_utc(r.timestamp).isoformat(), "device_serial": r.device_serial,
                        "metric": r.metric, "value": r.value, "unit": r.unit or "", "issuer": r.issuer or "",
                        "source": r.source})
            n += 1
        return n
    finally:
        if own:
            f.close()

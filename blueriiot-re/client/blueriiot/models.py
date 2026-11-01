"""Response models. Unknown fields are preserved (extra="allow") so nothing the
server sends is silently dropped; `raw` keeps the original dict where useful.

Units (source: field names + app UI; see research/endpoints.md):
  temperature  °C
  ph           pH
  orp          mV
  conductivity µS/cm   <- raw sensor value. NOT salinity.
  salinity     g/L     <- server-derived, only when the pool is salt-treated.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

UNITS: dict[str, str] = {
    "temperature": "°C",
    "ph": "pH",
    "orp": "mV",
    "conductivity": "µS/cm",
    "salinity": "g/L",
    # Additional fields in `measures` history points (units inferred from
    # name/magnitude, not documented by Blueriiot):
    "tds": "ppm",            # server-derived from conductivity
    "fcl_computed": "ppm",   # server-computed free chlorine estimate
    "ph_mv": "mV",           # raw pH electrode potential
    "batteryMV": "mV",
    "airtemp": "°C",         # weather data merged in by the server
    "windspeed": None,       # unit unknown
}
CORE_METRICS = ("temperature", "ph", "orp", "conductivity")


class _Model(BaseModel):
    model_config = ConfigDict(extra="allow", populate_by_name=True)


class SwimmingPool(_Model):
    swimming_pool_id: str
    name: str | None = None
    role: str | None = None
    swimming_pool: dict[str, Any] | None = None

    @property
    def display_name(self) -> str:
        return (self.swimming_pool or {}).get("name") or self.name or self.swimming_pool_id


class BlueDeviceRef(_Model):
    blue_device_serial: str
    swimming_pool_id: str | None = None
    blue_device: dict[str, Any] | None = None


class Measurement(_Model):
    name: str
    value: float | None = None
    timestamp: datetime | None = None
    expired: bool | None = None
    trend: str | None = None
    issuer: str | None = None  # gateway | sigfox | mobileapp | strip | ...
    priority: int | None = None
    ok_min: float | None = None
    ok_max: float | None = None
    warning_low: float | None = None
    warning_high: float | None = None
    gauge_min: float | None = None
    gauge_max: float | None = None

    @property
    def unit(self) -> str | None:
        return UNITS.get(self.name)


class LastMeasurements(_Model):
    status: str | None = None
    last_blue_measure_timestamp: datetime | None = None
    blue_device_serial: str | None = None
    swimming_pool_id: str | None = None
    data: list[Measurement] = Field(default_factory=list)

    def best(self, name: str) -> Measurement | None:
        """Most relevant reading for `name`: non-expired first, then newest."""
        cands = [m for m in self.data if m.name == name and m.value is not None]
        if not cands:
            return None
        cands.sort(key=lambda m: (not m.expired, m.timestamp or datetime.min), reverse=True)
        return cands[0]


class Reading(BaseModel):
    """One normalized historical point, as stored/exported locally."""

    device_serial: str
    metric: str
    timestamp: datetime          # measurement time (UTC) as reported by the server
    value: float
    unit: str | None = None
    issuer: str | None = None
    source: str = "unknown"      # which endpoint produced it (e.g. "lastMeasurements")

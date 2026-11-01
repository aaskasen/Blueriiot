"""Async, read-only client for the Blueriiot mobile-app API.

Confidence of each method is recorded in API_SPECIFICATION.md. Everything here
is GET-only except the login POST; the client refuses other methods.
"""

from __future__ import annotations

import asyncio
import logging
import os
import random
import time
from datetime import datetime, timedelta
from typing import Any

import httpx

from .auth import Session, sign_headers
from .history import dedupe, ensure_utc, readings_from_last_measurements, readings_from_measures, split_windows
from .models import BlueDeviceRef, LastMeasurements, Reading, SwimmingPool
from .redact import redact_path

log = logging.getLogger("blueriiot")

BASE_URL = "https://api.riiotlabs.com/prod/"
# The app identifies itself as BlueConnect/<version>; 4.18.0 is the current
# App Store version (checked 2026-10-18). Header is not known to be enforced.
DEFAULT_HEADERS = {
    "User-Agent": "BlueConnect/4.18.0",
    "Accept": "*/*",
    "Accept-Language": "en;q=1.0",
}


class BlueriiotError(Exception):
    pass


class AuthError(BlueriiotError):
    pass


class ApiError(BlueriiotError):
    def __init__(self, status: int, path: str, message: str):
        super().__init__(f"HTTP {status} for {path}: {message}")
        self.status, self.path, self.message = status, path, message


class HistoryUnavailable(BlueriiotError):
    """Raised while no server-side history route has been verified."""


class BlueriiotClient:
    def __init__(self, *, base_url: str = BASE_URL, timeout: float = 20.0,
                 min_interval: float = 1.0, max_retries: int = 4,
                 transport: httpx.AsyncBaseTransport | None = None):
        self._base = base_url if base_url.endswith("/") else base_url + "/"
        self._http = httpx.AsyncClient(timeout=timeout, transport=transport,
                                       headers=DEFAULT_HEADERS)
        self._session: Session | None = None
        self._email: str | None = None
        self._password: str | None = None
        self._min_interval = min_interval
        self._max_retries = max_retries
        self._last_call = 0.0
        self._lock = asyncio.Lock()
        self._known_ids: set[str] = set()
        # Verified 2026-10-18 from app traffic (capture 0001) and direct reads;
        # see research/historical-data.md. No server cap was observed up to
        # 365 days, but 30-day windows guard against silent truncation.
        self._history_route: dict[str, Any] | None = dict(
            path="swimming_pool/{pool_id}/blue/{serial}/measures", start="start_date",
            end="end_date", max_window=timedelta(days=30), extra={}, parse=readings_from_measures)

    async def __aenter__(self) -> "BlueriiotClient":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.aclose()

    async def aclose(self) -> None:
        await self._http.aclose()

    # ------------------------------------------------------------------ auth
    async def login(self, email: str | None = None, password: str | None = None) -> Session:
        """POST user/login. Credentials default to BLUERIIOT_EMAIL/PASSWORD env vars."""
        self._email = email or self._email or os.environ.get("BLUERIIOT_EMAIL")
        self._password = password or self._password or os.environ.get("BLUERIIOT_PASSWORD")
        if not self._email or not self._password:
            raise AuthError("missing credentials (set BLUERIIOT_EMAIL / BLUERIIOT_PASSWORD in .env)")
        await self._throttle()
        resp = await self._http.post(self._base + "user/login",
                                     json={"email": self._email, "password": self._password})
        log.info("POST user/login -> %s", resp.status_code)
        if resp.status_code in (400, 401, 403):
            raise AuthError(f"login rejected (HTTP {resp.status_code}): {_error_message(resp)}")
        if resp.status_code != 200:
            raise ApiError(resp.status_code, "user/login", _error_message(resp))
        self._session = Session.from_login_response(resp.json())
        return self._session

    async def _ensure_session(self) -> Session:
        if self._session is None or self._session.needs_renewal():
            await self.login()
        assert self._session is not None
        return self._session

    # ------------------------------------------------------------ transport
    async def _throttle(self) -> None:
        async with self._lock:
            wait = self._min_interval - (time.monotonic() - self._last_call)
            if wait > 0:
                await asyncio.sleep(wait)
            self._last_call = time.monotonic()

    async def get_json(self, path: str, params: dict[str, Any] | None = None) -> Any:
        """Signed GET with throttling, retry/backoff on 429/5xx and one re-login on 401/403."""
        relogged = False
        for attempt in range(self._max_retries + 1):
            session = await self._ensure_session()
            req = self._http.build_request("GET", self._base + path.lstrip("/"),
                                           params={k: v for k, v in (params or {}).items() if v is not None})
            url = str(req.url)
            signed = sign_headers(session, "GET", url, {"Accept": DEFAULT_HEADERS["Accept"]})
            req.headers.update(signed)
            await self._throttle()
            try:
                resp = await self._http.send(req)
            except httpx.TransportError as err:
                if attempt == self._max_retries:
                    raise BlueriiotError(f"network error for {redact_path(path, self._known_ids)}: {err}") from err
                await _backoff(attempt)
                continue
            log.info("GET %s -> %s", redact_path(url.replace(self._base, ""), self._known_ids), resp.status_code)
            if resp.status_code in (401, 403) and not relogged:
                relogged = True
                self._session = None
                continue
            if resp.status_code == 429 or resp.status_code >= 500:
                if attempt < self._max_retries:
                    await _backoff(attempt, resp.headers.get("Retry-After"))
                    continue
            if resp.status_code != 200:
                raise ApiError(resp.status_code, redact_path(path, self._known_ids), _error_message(resp))
            data = resp.json()
            if isinstance(data, dict) and "errorMessage" in data:
                raise ApiError(resp.status_code, redact_path(path, self._known_ids), data["errorMessage"])
            return data
        raise BlueriiotError("retries exhausted")

    def _remember(self, *ids: str | None) -> None:
        self._known_ids.update(i for i in ids if i)

    # ------------------------------------------------- source-confirmed reads
    async def get_user(self) -> dict:
        return await self.get_json("user")

    async def get_pools(self, deleted: bool = False) -> list[SwimmingPool]:
        data = await self.get_json("swimming_pool", {"deleted": str(deleted).lower()})
        pools = [SwimmingPool.model_validate(p) for p in data.get("data", [])]
        self._remember(*(p.swimming_pool_id for p in pools))
        return pools

    async def get_pool(self, pool_id: str) -> dict:
        return await self.get_json(f"swimming_pool/{pool_id}")

    async def get_pool_blue_devices(self, pool_id: str) -> list[BlueDeviceRef]:
        data = await self.get_json(f"swimming_pool/{pool_id}/blue")
        devs = [BlueDeviceRef.model_validate(d) for d in data.get("data", [])]
        self._remember(*(d.blue_device_serial for d in devs))
        return devs

    async def get_blue_device(self, serial: str) -> dict:
        """Device detail: battery, last BLE/Sigfox measure, firmware, gateway info."""
        return await self.get_json(f"blue/{serial}")

    async def get_blues(self) -> dict:
        return await self.get_json("blue")

    async def get_blue_compatibility(self, serial: str) -> dict:
        return await self.get_json(f"blue/{serial}/compatibility")

    async def get_last_measurements_raw(self, pool_id: str, serial: str,
                                        mode: str = "blue_and_strip") -> dict:
        return await self.get_json(f"swimming_pool/{pool_id}/blue/{serial}/lastMeasurements",
                                   {"mode": mode})

    async def get_latest_measurement(self, pool_id: str, device_id: str) -> LastMeasurements:
        return LastMeasurements.model_validate(await self.get_last_measurements_raw(pool_id, device_id))

    async def get_pool_status(self, pool_id: str) -> dict:
        return await self.get_json(f"swimming_pool/{pool_id}/status")

    async def get_feed(self, pool_id: str, lang: str = "en") -> dict:
        return await self.get_json(f"swimming_pool/{pool_id}/feed", {"lang": lang})

    async def get_guidance(self, pool_id: str, lang: str = "en", mode: str = "interactive_v03") -> dict:
        return await self.get_json(f"swimming_pool/{pool_id}/guidance", {"lang": lang, "mode": mode})

    async def get_guidance_history(self, pool_id: str, lang: str = "en") -> dict:
        return await self.get_json(f"swimming_pool/{pool_id}/guidance/history", {"lang": lang})

    async def get_chemistry(self, pool_id: str) -> dict:
        return await self.get_json(f"swimming_pool/{pool_id}/chemistry")

    async def get_weather(self, pool_id: str, lang: str = "en") -> dict:
        return await self.get_json(f"swimming_pool/{pool_id}/weather", {"lang": lang})

    async def get_devices(self) -> list[dict]:
        """All (pool, device) pairs owned by the account, with device detail."""
        out = []
        for pool in await self.get_pools():
            for dev in await self.get_pool_blue_devices(pool.swimming_pool_id):
                detail = await self.get_blue_device(dev.blue_device_serial)
                out.append({"pool_id": pool.swimming_pool_id, "pool_name": pool.display_name,
                            "serial": dev.blue_device_serial, "device": detail})
        return out

    # ---------------------------------------------------------------- history
    async def get_measures_raw(self, pool_id: str, serial: str, start: datetime, end: datetime) -> dict:
        """One raw `measures` call. Response: {"data": [{created, data:{metric: value}}], "ranges": {...}}.

        Bounds are compared as strings against `created` server-side, so always
        send full ISO-8601 UTC timestamps. Missing params -> HTTP 200 + errorMessage.
        """
        return await self.get_json(f"swimming_pool/{pool_id}/blue/{serial}/measures",
                                   {"start_date": _iso(ensure_utc(start)), "end_date": _iso(ensure_utc(end))})

    def configure_history_route(self, path_template: str, *, start_param: str, end_param: str,
                                max_window: timedelta, extra_params: dict[str, Any] | None = None,
                                parse=None) -> None:
        """Install the history route once it is verified from traffic.

        path_template may reference {pool_id} and {serial}. `parse(payload, serial)`
        must return list[Reading].
        """
        self._history_route = dict(path=path_template, start=start_param, end=end_param,
                                   max_window=max_window, extra=extra_params or {}, parse=parse)

    async def get_measurement_history(self, pool_id: str, device_id: str,
                                      start: datetime, end: datetime) -> list[Reading]:
        r = self._history_route
        if r is None:
            raise HistoryUnavailable(
                "No server-side measurement-history route has been verified yet. "
                "See research/historical-data.md. Use the local accumulator "
                "(blueriiot.store) meanwhile.")
        readings: list[Reading] = []
        for a, b in split_windows(start, end, r["max_window"]):
            payload = await self.get_json(
                r["path"].format(pool_id=pool_id, serial=device_id),
                {**r["extra"], r["start"]: _iso(a), r["end"]: _iso(b)})
            readings.extend(r["parse"](payload, device_id))
        start, end = ensure_utc(start), ensure_utc(end)
        return [x for x in dedupe(readings) if start <= x.timestamp < end]

    async def snapshot_readings(self, pool_id: str, device_id: str) -> list[Reading]:
        """Current readings normalized as history rows (for local accumulation)."""
        raw = await self.get_last_measurements_raw(pool_id, device_id)
        return readings_from_last_measurements(raw, device_id)


def _iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def _error_message(resp: httpx.Response) -> str:
    try:
        body = resp.json()
        return str(body.get("errorMessage") or body.get("message") or body)[:200]
    except Exception:
        return resp.text[:200]


async def _backoff(attempt: int, retry_after: str | None = None) -> None:
    if retry_after and retry_after.isdigit():
        await asyncio.sleep(min(int(retry_after), 60))
        return
    await asyncio.sleep(min(2 ** attempt, 30) + random.uniform(0, 0.5))

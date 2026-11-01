import io
import json
from datetime import datetime, timedelta, timezone

import httpx
import pytest
import respx

from blueriiot import BlueriiotClient, HistoryUnavailable, LastMeasurements, ReadingStore, write_csv
from blueriiot.auth import Session
from blueriiot.history import dedupe, readings_from_last_measurements, split_windows
from blueriiot.redact import redact
from conftest import BASE, FIXTURES, LOGIN, POOL, SERIAL

UTC = timezone.utc


def client():
    return BlueriiotClient(min_interval=0, max_retries=2)


@respx.mock
async def test_login_then_signed_get(last_measurements):
    login = respx.post(BASE + "user/login").respond(json=LOGIN)
    lm = respx.get(BASE + f"swimming_pool/{POOL}/blue/{SERIAL}/lastMeasurements").respond(json=last_measurements)
    async with client() as c:
        res = await c.get_latest_measurement(POOL, SERIAL)
    assert login.call_count == 1
    assert login.calls[0].request.content and b"pool@example.com" in login.calls[0].request.content
    req = lm.calls[0].request
    assert req.url.params["mode"] == "blue_and_strip"
    auth = req.headers["Authorization"]
    assert auth.startswith("AWS4-HMAC-SHA256 Credential=ASIAFAKEFAKEFAKEFAKE/")
    assert "/eu-west-1/execute-api/aws4_request" in auth
    assert req.headers["X-Amz-Security-Token"] == "fake-session-token"
    assert isinstance(res, LastMeasurements)


def test_best_prefers_non_expired(last_measurements):
    lm = LastMeasurements.model_validate(last_measurements)
    assert lm.best("ph").value == 7.4
    assert lm.best("conductivity").unit == "µS/cm"
    assert lm.best("salinity") is None  # conductivity is never relabelled as salinity


@respx.mock
async def test_relogin_on_403_and_retry_on_500(last_measurements):
    login = respx.post(BASE + "user/login").respond(json=LOGIN)
    route = respx.get(BASE + "user").mock(side_effect=[
        httpx.Response(403, json={"message": "expired"}),
        httpx.Response(502, json={"message": "bad gateway"}),
        httpx.Response(200, json={"user_id": "x"}),
    ])
    async with client() as c:
        assert (await c.get_user())["user_id"] == "x"
    assert login.call_count == 2 and route.call_count == 3


@respx.mock
async def test_error_message_in_200_body_raises():
    respx.post(BASE + "user/login").respond(json=LOGIN)
    respx.get(BASE + "user").respond(json={"errorMessage": "boom"})
    async with client() as c:
        with pytest.raises(Exception, match="boom"):
            await c.get_user()


def test_session_renewal_margin():
    s = Session.from_login_response(LOGIN)
    assert not s.needs_renewal(datetime(2098, 12, 31, tzinfo=UTC))
    assert s.needs_renewal(datetime(2098, 12, 31, 23, 58, tzinfo=UTC))


@respx.mock
async def test_default_history_uses_measures_route():
    measures = json.loads((FIXTURES / "measures.json").read_text())
    respx.post(BASE + "user/login").respond(json=LOGIN)
    route = respx.get(BASE + f"swimming_pool/{POOL}/blue/{SERIAL}/measures").respond(json=measures)
    async with client() as c:
        out = await c.get_measurement_history(POOL, SERIAL, datetime(2026, 9, 18, tzinfo=UTC),
                                              datetime(2026, 10, 18, tzinfo=UTC))
    assert route.call_count == 1  # exactly one 30-day window
    params = route.calls[0].request.url.params
    assert params["start_date"] == "2026-09-18T00:00:00.000Z" and params["end_date"] == "2026-10-18T00:00:00.000Z"
    # the same payload is returned for every window in this mock; points are deduped by time
    by_metric = {(r.metric, r.timestamp.isoformat()): r for r in out}
    assert by_metric[("conductivity", "2026-10-17T17:45:00+00:00")].unit == "µS/cm"
    assert by_metric[("orp", "2026-10-17T18:57:00+00:00")].value == 298
    assert ("salinity", "2026-10-17T17:45:00+00:00") in by_metric  # kept separate from conductivity
    assert all(r.source == "measures" for r in out)


async def test_history_unavailable_when_route_cleared():
    async with client() as c:
        c._history_route = None
        with pytest.raises(HistoryUnavailable):
            await c.get_measurement_history(POOL, SERIAL, datetime(2026, 9, 1, tzinfo=UTC),
                                            datetime(2026, 10, 1, tzinfo=UTC))


@respx.mock
async def test_configured_history_splits_and_dedupes(last_measurements):
    respx.post(BASE + "user/login").respond(json=LOGIN)
    route = respx.get(BASE + f"swimming_pool/{POOL}/blue/{SERIAL}/hypothetical").respond(json=last_measurements)
    async with client() as c:
        c.configure_history_route("swimming_pool/{pool_id}/blue/{serial}/hypothetical",
                                  start_param="from", end_param="to", max_window=timedelta(days=7),
                                  parse=lambda p, s: readings_from_last_measurements(p, s))
        out = await c.get_measurement_history(POOL, SERIAL, datetime(2026, 10, 1, tzinfo=UTC),
                                              datetime(2026, 10, 31, tzinfo=UTC))
    assert route.call_count == 5  # 30 days / 7-day windows
    assert route.calls[0].request.url.params["from"] == "2026-10-01T00:00:00.000Z"
    assert len(out) == 4  # same 4 non-expired points every window -> deduped


def test_split_windows_contiguous():
    w = list(split_windows(datetime(2026, 1, 1), datetime(2026, 1, 31), timedelta(days=7)))
    assert w[0][0].tzinfo is not None and w[-1][1] == datetime(2026, 1, 31, tzinfo=UTC)
    assert all(a[1] == b[0] for a, b in zip(w, w[1:]))


def test_dedupe_and_store_and_csv(tmp_path, last_measurements):
    rows = readings_from_last_measurements(last_measurements, SERIAL)
    assert {r.metric for r in rows} == {"temperature", "ph", "orp", "conductivity"}
    assert len(dedupe(rows + rows)) == 4
    store = ReadingStore(tmp_path / "r.sqlite")
    assert store.add(rows) == 4 and store.add(rows) == 0
    got = store.query(SERIAL, datetime(2026, 10, 1, tzinfo=UTC), datetime(2026, 11, 1, tzinfo=UTC))
    buf = io.StringIO()
    assert write_csv(got, buf) == 4
    assert buf.getvalue().splitlines()[0] == "timestamp_utc,device_serial,metric,value,unit,issuer,source"


def test_redaction():
    out = redact({**LOGIN, "email": "a@b.com", "swimming_pool_id": POOL,
                  "geoloc": {"latitude": 55.6, "longitude": 12.5}, "note": f"pool {POOL}"})
    assert out["credentials"] == {"access_key": "<redacted>", "secret_key": "<redacted>",
                                  "session_token": "<redacted>", "expiration": "2099-01-01T00:00:00.000Z"}
    assert out["email"] == "<redacted>" and out["swimming_pool_id"] == "<id>"
    assert out["geoloc"] == "<redacted-pii>" and POOL not in out["note"]  # whole location block

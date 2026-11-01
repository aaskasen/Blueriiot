"""Redaction helpers for logs and fixtures."""

from __future__ import annotations

import re
from typing import Any

# Keys are compared after normalization: lower-case, "_" and "-" removed,
# so first_name / firstName / FIRST-NAME all match "firstname".
SECRET_KEYS = {
    "password", "token", "accesskey", "secretkey", "sessiontoken", "identityid", "useridentityid",
    "authorization", "xamzsecuritytoken", "cookie", "setcookie", "email", "userid",
}
ID_KEYS = {
    "swimmingpoolid", "bluedeviceserial", "serial", "sn", "mainswimmingpoolid", "bluedeviceid",
    "gatewayserial", "gatewayid", "sigfoxid", "deviceid", "macaddress", "mac",
}
GEO_KEYS = {"latitude", "longitude", "lat", "lng", "lon", "address", "city", "zip", "zipcode",
            "postalcode", "street", "firstname", "lastname", "phone", "swpname",
            "geoloc", "lastgeolocsigfox", "sigfoxgeoloc"}

_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
_MAC = re.compile(r"(?:[0-9A-F]{2}:){5}[0-9A-F]{2}", re.I)


_BLUE_SEGMENT = re.compile(r"(/blue/)(?!compatibility\b)([A-Za-z0-9]{6,})")


def redact_path(path: str, known_ids: set[str] | None = None) -> str:
    out = _UUID.sub("{uuid}", path)
    out = _BLUE_SEGMENT.sub(r"\1{serial}", out)
    for ident in known_ids or ():
        if ident:
            out = out.replace(ident, "{id}")
    return out


def redact(obj: Any, known_ids: set[str] | None = None) -> Any:
    """Deep-copy `obj` with secrets/IDs/location replaced by placeholders."""
    if isinstance(obj, dict):
        res = {}
        for k, v in obj.items():
            lk = re.sub(r"[_-]", "", str(k).lower())
            if lk in SECRET_KEYS:
                res[k] = "<redacted>"
            elif lk in ID_KEYS and isinstance(v, (str, int)):
                res[k] = "<id>"
            elif lk in GEO_KEYS:
                res[k] = "<redacted-pii>"
            else:
                res[k] = redact(v, known_ids)
        return res
    if isinstance(obj, list):
        return [redact(v, known_ids) for v in obj]
    if isinstance(obj, str):
        s = _EMAIL.sub("<email>", obj)
        s = _UUID.sub("<uuid>", s)
        s = _MAC.sub("<mac>", s)
        for ident in known_ids or ():
            if ident and ident in s:
                s = s.replace(ident, "<id>")
        return s
    return obj

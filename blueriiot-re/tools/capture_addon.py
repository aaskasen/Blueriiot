"""mitmproxy addon: record only Blueriiot/Riiot API traffic, with a redacted copy.

    mitmdump -s tools/capture_addon.py --mode local:"Blueriiot" \
             --set block_global=false

(or --mode regular@8080 when proxying a physical iPhone).

Writes one JSON per exchange:
  captures/raw/flows/NNNN.json        full request/response (git-ignored)
  captures/sanitized/flows/NNNN.json  secrets, IDs, PII redacted
plus captures/sanitized/flow_index.tsv (seq, time, method, redacted path, status).
Non-matching hosts are passed through untouched and not recorded.
"""

from __future__ import annotations

import importlib.util
import json
import re
import time
from pathlib import Path

from mitmproxy import http

ROOT = Path(__file__).resolve().parents[1]

# Load redact.py by file path: mitmproxy's bundled Python lacks the client's
# dependencies (httpx, botocore), so importing the package would fail.
_spec = importlib.util.spec_from_file_location("bri_redact", ROOT / "client/blueriiot/redact.py")
_redact = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_redact)
redact, redact_path = _redact.redact, _redact.redact_path

HOSTS = re.compile(r"(riiotlabs\.com|blueriiot\.com|amazonaws\.com|fluidra)", re.I)
RAW = ROOT / "captures/raw/flows"
SAN = ROOT / "captures/sanitized/flows"
HDR_SECRETS = {"authorization", "x-amz-security-token", "cookie", "set-cookie", "x-api-key"}


class Recorder:
    def __init__(self) -> None:
        RAW.mkdir(parents=True, exist_ok=True)
        SAN.mkdir(parents=True, exist_ok=True)
        self.seq = len(list(RAW.glob("*.json")))
        self.index = (ROOT / "captures/sanitized/flow_index.tsv").open("a")

    def response(self, flow: http.HTTPFlow) -> None:
        if not HOSTS.search(flow.request.pretty_host):
            return
        self.seq += 1
        rec = {
            "seq": self.seq,
            "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "request": {
                "method": flow.request.method,
                "url": flow.request.pretty_url,
                "headers": dict(flow.request.headers),
                "body": _body(flow.request),
            },
            "response": {
                "status": flow.response.status_code,
                "headers": dict(flow.response.headers),
                "body": _body(flow.response),
            },
        }
        name = f"{self.seq:04d}.json"
        (RAW / name).write_text(json.dumps(rec, indent=2, ensure_ascii=False))
        san = redact(rec)
        for part in ("request", "response"):
            san[part]["headers"] = {k: ("<redacted>" if k.lower() in HDR_SECRETS else v)
                                    for k, v in rec[part]["headers"].items()}
        san["request"]["url"] = redact_path(rec["request"]["url"])
        (SAN / name).write_text(json.dumps(san, indent=2, ensure_ascii=False))
        self.index.write(f"{self.seq}\t{rec['time']}\t{flow.request.method}\t"
                         f"{san['request']['url']}\t{flow.response.status_code}\n")
        self.index.flush()


def _body(msg):
    if not msg.content:
        return None
    try:
        return json.loads(msg.get_text(strict=False) or "")
    except (ValueError, TypeError):
        txt = msg.get_text(strict=False)
        return txt[:4000] if txt is not None else f"<{len(msg.content)} bytes binary>"


addons = [Recorder()]

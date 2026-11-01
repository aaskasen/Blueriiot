import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "client"))

FIXTURES = ROOT / "tests" / "fixtures"
BASE = "https://api.riiotlabs.com/prod/"
POOL = "00000000-0000-4000-8000-000000000000"
SERIAL = "SERIAL001"

LOGIN = {
    "identity_id": "eu-west-1:00000000-0000-0000-0000-000000000000",
    "token": "fake-jwt",
    "credentials": {
        "access_key": "ASIAFAKEFAKEFAKEFAKE",
        "secret_key": "fakefakefakefakefakefakefakefakefakefake",
        "session_token": "fake-session-token",
        "expiration": "2099-01-01T00:00:00.000Z",
    },
}


@pytest.fixture
def last_measurements():
    return json.loads((FIXTURES / "last_measurements.json").read_text())


@pytest.fixture(autouse=True)
def _creds(monkeypatch):
    monkeypatch.setenv("BLUERIIOT_EMAIL", "pool@example.com")
    monkeypatch.setenv("BLUERIIOT_PASSWORD", "not-a-real-password")

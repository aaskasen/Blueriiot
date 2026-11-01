"""Authentication for the Blueriiot mobile-app API (api.riiotlabs.com/prod).

Flow (source-confirmed in MBW.Client.BlueRiiotApi, homebridge-blueconnect,
ha-pool-management-blueriiot; see research/authentication.md):

1. POST {BASE}/user/login  {"email", "password"}  (unsigned)
   -> {"identity_id", "token", "credentials": {access_key, secret_key,
       session_token, expiration}}
   The credentials are temporary AWS (Cognito identity pool) credentials.
2. Every other request is AWS SigV4-signed, service "execute-api",
   region "eu-west-1", with X-Amz-Security-Token = session_token.

There is no refresh endpoint in any public source; "renewal" is re-login
shortly before `expiration`.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from urllib.parse import urlsplit

from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials

AWS_REGION = "eu-west-1"
AWS_SERVICE = "execute-api"
REFRESH_MARGIN = timedelta(minutes=5)


@dataclass
class Session:
    identity_id: str
    access_key: str
    secret_key: str = field(repr=False)
    session_token: str = field(repr=False)
    expiration: datetime
    token: str | None = field(default=None, repr=False)

    @classmethod
    def from_login_response(cls, data: dict) -> "Session":
        creds = data.get("credentials") or {}
        missing = [k for k in ("access_key", "secret_key", "session_token") if not creds.get(k)]
        if missing:
            raise ValueError(f"login response lacks credentials fields: {missing}")
        return cls(
            identity_id=data.get("identity_id", ""),
            access_key=creds["access_key"],
            secret_key=creds["secret_key"],
            session_token=creds["session_token"],
            expiration=parse_expiration(creds.get("expiration")),
            token=data.get("token"),
        )

    def needs_renewal(self, now: datetime | None = None) -> bool:
        now = now or datetime.now(timezone.utc)
        return now >= self.expiration - REFRESH_MARGIN


def parse_expiration(value) -> datetime:
    """Parse the `expiration` field; fall back to +55 min if unparseable."""
    if isinstance(value, (int, float)):
        secs = value / 1000 if value > 1e12 else value
        return datetime.fromtimestamp(secs, tz=timezone.utc)
    if isinstance(value, str):
        try:
            dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return datetime.now(timezone.utc) + timedelta(minutes=55)


def sign_headers(session: Session, method: str, url: str, headers: dict[str, str],
                 body: bytes = b"") -> dict[str, str]:
    """Return a copy of `headers` with SigV4 Authorization/X-Amz-* added."""
    creds = Credentials(session.access_key, session.secret_key, session.session_token)
    host = urlsplit(url).netloc
    req = AWSRequest(method=method, url=url, data=body, headers={**headers, "Host": host})
    SigV4Auth(creds, AWS_SERVICE, AWS_REGION).add_auth(req)
    return dict(req.headers.items())

# Authentication

**Status: Verified** (live login and signed requests on 2026-10-18; matches app traffic).

## Flow

1. `POST https://api.riiotlabs.com/prod/user/login`, body `{"email": …, "password": …}`, unsigned.
2. The response contains:
   ```json
   {"identity_id": "eu-west-1:<uuid>", "token": "<jwt>",
    "credentials": {"access_key": "ASIA…", "secret_key": "…", "session_token": "…",
                    "expiration": "2026-10-18T15:53:52.000Z"}}
   ```
   These are temporary AWS credentials from a Cognito identity pool (`eu-west-1:` identity ID).
3. Each subsequent request is signed with **AWS SigV4**, service `execute-api`, region `eu-west-1`, plus the header `X-Amz-Security-Token: <session_token>`.

The official app (Dart client) sends exactly these headers on `measures`: `user-agent: Dart/3.6 (dart:io)`, `x-amz-date`, `x-amz-security-token`, `authorization`, `content-type: application/json; charset=utf-8` (capture #1).

## Lifetime and renewal

- The observed credential lifetime is **about 1 hour** (login 14:54Z → expiration 15:53:52Z).
- No refresh endpoint exists in any public source or in the app traffic. Renewal is re-login.
- The client re-logs in 5 min before `expiration` (same margin as MBW `UsernamePasswordRequestSigner.cs:27`). It also re-logs in once on 401/403.
- Note: homebridge-blueconnect `blueriiot-api.js:62` has an inverted check (`if (expire > now)`), so it re-logs in on every call. Don't copy it.

## Secrets handling

- Credentials are read from `.env` (git-ignored); tests use fake values.
- AWS creds live only in memory. They are never written to disk, logs or the browser.
- `redact.py` strips credentials, tokens, email, names, serials, MACs and location from saved fixtures.

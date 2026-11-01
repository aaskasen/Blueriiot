# Captures

The evidence behind the API documentation (sanitized request/response captures from the owner's
account, plus the app-traffic flows) is **kept locally and not published**. Even redacted, it
describes one specific pool and device.

Published here:
- `sanitized/history_probe.json` — the `measures` endpoint characterization (counts, date ranges, status codes only).

To regenerate your own evidence locally (written to git-ignored folders):

```bash
.venv/bin/python examples/probe_account.py     # -> captures/raw/ and captures/sanitized/
.venv/bin/python tools/probe_history.py        # -> captures/sanitized/history_probe.json
mitmdump -s tools/capture_addon.py --mode local:Runner   # app traffic -> captures/{raw,sanitized}/flows/
```

Synthetic fixtures with the same shapes are in `../tests/fixtures/`.

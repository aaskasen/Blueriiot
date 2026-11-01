# App analysis

## Listing

- App Store id 1109733256, bundle `com.riiotlabs.blue`, version **4.18.0** (2025-01-28), min iOS 15.5, seller Fluidra Global Distribution S.L.
- Mac availability: "Requires macOS 12.4 or later and a Mac with Apple M1 chip or later" ("Designed for iPad. Not verified for macOS").
- Bundle executable is `Runner`, so it's a **Flutter** app. The HTTP client is Dart (`Dart/3.6 (dart:io)` UA), which **ignores system proxy settings**.

## Simulator feasibility

Not attempted. The App Store build is a FairPlay-protected device build and can't be installed into the Simulator. Using an Apple-Silicon Mac made it unnecessary: the official app runs natively on this M4 Max.

## Traffic inspection

- Tool: mitmproxy 12.1.1 in **local (process-redirect) mode** (`--mode local:Runner`), so only the Blueriiot process was intercepted. The owner trusted the mitmproxy CA and approved the network extension.
- **No certificate pinning:** the app accepted the mitmproxy CA, and `api.riiotlabs.com` requests were decrypted.
- Captured: `GET measures` ×2 (24 h), `GET user`. Other traffic: OneSignal (push), Firebase Remote Config realtime stream (HTTP/3), Crashlytics/Firelog, Google Analytics. None was recorded by the addon (host filter).
- **Limitation:** after a relaunch under the proxy, the app stalled at the splash screen. The Firebase Remote Config realtime stream (HTTP/3) kept failing with "Connection closed", which is the likely cause. The UI walk-through (range switching, Premium screens) was abandoned; the endpoint was characterized directly instead (`historical-data.md`). If more app flows are needed, re-run with `--allow-hosts 'riiotlabs\.com'` so Firebase traffic passes through untouched.
- The CA should be removed afterwards: `sudo security delete-certificate -c mitmproxy /Library/Keychains/System.keychain`.

## Static analysis

Not needed once traffic revealed the route. The app binary is FairPlay-encrypted, and decrypting it was out of scope.

#!/bin/zsh
# Build, audit, and package Pool Monitor as a signed (optionally notarized) DMG.
#
#   ./package.sh                 # build + audit + DMG
#   ./package.sh --notarize      # also notarize + staple (needs keychain profile "PoolMonitorNotary")
#
# The audit fails the build if any personal value from ../blueriiot-re/.env or the
# captured account data (email, password, serials, pool id/name, MAC) appears in the bundle.
set -euo pipefail
cd "$(dirname "$0")"

TEAM=4JAWF8AN8G
# Signing identity is looked up in the keychain, so no personal name is hard-coded here.
IDENTITY=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .* ($TEAM)\)\"/\1/p" | head -1)
[[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' identity for team $TEAM in the keychain"; exit 1; }
PROFILE=PoolMonitorNotary

rm -rf build/PoolMonitor.xcarchive dist/export dist/dmg-root dist/PoolMonitor.dmg
mkdir -p dist
xcodebuild archive -project PoolWidget.xcodeproj -scheme PoolMonitor -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/PoolMonitor.xcarchive \
  -derivedDataPath build/dd-release -allowProvisioningUpdates -quiet
xcodebuild -exportArchive -archivePath build/PoolMonitor.xcarchive \
  -exportOptionsPlist dist/ExportOptions.plist -exportPath dist/export -allowProvisioningUpdates -quiet
APP=dist/export/PoolMonitor.app
codesign --verify --deep --strict "$APP"

echo "== credential audit"
python3 - "$APP" <<'EOF'
import json, pathlib, re, sys
app = pathlib.Path(sys.argv[1]); re_root = pathlib.Path('../blueriiot-re')
needles = {}
env = re_root / '.env'
if env.exists():
    kv = dict(l.split('=', 1) for l in env.read_text().splitlines() if '=' in l and not l.startswith('#'))
    for k in ('BLUERIIOT_EMAIL', 'BLUERIIOT_PASSWORD'):
        if kv.get(k, '').strip(): needles[k] = kv[k].strip()
    if 'BLUERIIOT_EMAIL' in needles: needles['email local part'] = needles['BLUERIIOT_EMAIL'].split('@')[0]
raw = re_root / 'captures/raw'
for f in raw.rglob('*.json') if raw.exists() else []:
    t = f.read_text(errors='ignore')
    for m in re.findall(r'"(?:serial|blue_device_serial|SN|sn|swimming_pool_id|gateway_id)"\s*:\s*"([^"]+)"', t):
        needles[f'id {m[:3]}…'] = m
    for m in re.findall(r'"swp_name"\s*:\s*"([^"]+)"', t):
        needles['pool name'] = m
pats = {'AWS key': rb'(AKIA|ASIA)[A-Z0-9]{16}', 'JWT': rb'eyJ[A-Za-z0-9_-]{10,}\.',
        'env var': rb'BLUERIIOT_(EMAIL|PASSWORD)', 'home path': rb'/Users/[A-Za-z]+/'}
bad = []
for f in (p for p in app.rglob('*') if p.is_file()):
    b = f.read_bytes()
    for name, v in needles.items():
        if v.encode() in b or v.encode('utf-16-le') in b:   # case-sensitive: avoids e.g. "PoolEntry" ~ "poolen"
            bad.append((f.name, name))
    for name, p in pats.items():
        if re.search(p, b): bad.append((f.name, name))
print(f"checked {len(needles)} personal values + {len(pats)} patterns")
if bad:
    print("FAILED:", bad); sys.exit(1)
print("clean: no credentials or personal identifiers in the bundle")
EOF

echo "== dmg"
mkdir dist/dmg-root
cp -R "$APP" dist/dmg-root/
ln -s /Applications dist/dmg-root/Applications
hdiutil create -volname "Pool Monitor" -srcfolder dist/dmg-root -ov -format UDZO dist/PoolMonitor.dmg -quiet
rm -rf dist/dmg-root
codesign --sign "$IDENTITY" --timestamp dist/PoolMonitor.dmg

if [[ "${1:-}" == "--notarize" ]]; then
  echo "== notarize"
  xcrun notarytool submit dist/PoolMonitor.dmg --keychain-profile "$PROFILE" --wait
  xcrun stapler staple dist/PoolMonitor.dmg
  spctl -a -vvv -t install dist/PoolMonitor.dmg
fi
echo "done: dist/PoolMonitor.dmg"

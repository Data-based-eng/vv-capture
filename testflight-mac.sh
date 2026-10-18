#!/bin/bash
# TestFlight upload for VV Capture (macOS).
#
# Run this in a LOCAL Mac Terminal (code signing needs the login keychain;
# it does not work over SSH).
#
# Prerequisites (one-time):
#   1. App Store Connect -> My Apps -> + -> New App: platform macOS,
#      name "VV Capture Mac", bundle ID com.visionvend.capture.mac, SKU com.visionvend.capture.mac.
#      (Bundle ID + provisioning profile were created 2026-10-18 via API.)
#
# What it does: preflight (app record exists) -> bump Mac build number ->
# archive (manual signing, Apple Distribution) -> export .pkg ->
# upload to TestFlight via altool + App Store Connect API key.
set -euo pipefail
cd "$(dirname "$0")"

SCHEME="VVCaptureMac"
PROJECT="VVCapture.xcodeproj"
BID="com.visionvend.capture.mac"
PROFILE_UUID="a229fa21-e3cc-4623-b0e5-b97b574e0994"
KEY_ID="28B8DS36N6"
ISSUER_ID="a4bb7486-0692-4f20-917e-58f42269625e"
TEAM_ID="F567VF9J9R"
P8="/Users/core/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"

echo "==> Preflight: app record for $BID must exist in App Store Connect"
python3 - "$BID" "$P8" "$KEY_ID" "$ISSUER_ID" <<'PYEOF'
import sys, json, time, urllib.request
import jwt
bid, p8path, kid, iss = sys.argv[1:5]
with open(p8path) as f:
    key = f.read()
now = int(time.time())
tok = jwt.encode({"iss": iss, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                 key, algorithm="ES256", headers={"kid": kid})
req = urllib.request.Request(
    "https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=" + bid,
    headers={"Authorization": "Bearer " + tok})
with urllib.request.urlopen(req, timeout=30) as r:
    d = json.loads(r.read())
if not d.get("data"):
    print("ABORT: no App Store Connect app for bundle ID " + bid, file=sys.stderr)
    print("Create it: App Store Connect -> My Apps -> + -> New App (macOS).", file=sys.stderr)
    sys.exit(1)
print("  app record OK:", d["data"][0]["id"])
PYEOF

echo "==> Bumping Mac build number"
python3 - "VVCapture.xcodeproj" "com.visionvend.capture.mac" <<'PYEOF'
import io, re, sys
proj, bid = sys.argv[1:3]
t = io.open(proj, encoding="utf-8").read()
pat = re.compile(r"(\n\t+[0-9A-Za-z]{8,24}(?: /\*.*?\*/)? = \{\n\t+isa = XCBuildConfiguration;.*?\n\t+\};)", re.S)
count = [0]
def repl(m):
    block = m.group(1)
    if bid in block:
        bm = re.search(r"CURRENT_PROJECT_VERSION = (\d+);", block)
        if bm:
            block = block[:bm.start(1)] + str(int(bm.group(1)) + 1) + block[bm.end(1):]
            count[0] += 1
    return block
t = pat.sub(repl, t)
io.open(proj, "w", encoding="utf-8").write(t)
print("  bumped %d Mac config(s)" % count[0])
PYEOF

STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="build/${SCHEME}-${STAMP}.xcarchive"
EXPORT_DIR="build/${SCHEME}-${STAMP}-export"
EXPORT_PLIST="$(mktemp /tmp/ExportOptions-${SCHEME}.plist.XXXXXX)"

echo "==> Archiving $SCHEME (Release)..."
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" archive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Distribution" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID"

cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Exporting..."
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_PLIST" -exportPath "$EXPORT_DIR"

PKG="$(ls "$EXPORT_DIR"/*.pkg | head -1)"
echo "==> Uploading $PKG to TestFlight..."
xcrun altool --upload-app --type macos -f "$PKG" \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"

echo "done: $SCHEME uploaded. Build appears in TestFlight after Apple processing (~10-30 min)."
echo "archive: $ARCHIVE"

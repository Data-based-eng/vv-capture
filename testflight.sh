#!/bin/bash
# TestFlight upload for the vv-capture iOS app (build 1, first upload).
#
# Run this in your LOCAL Terminal (signing needs your keychain;
# it does not work over SSH).
#
# NOTE: ExportOptions.plist sets destination=upload, so
# xcodebuild -exportArchive uploads straight to App Store Connect —
# no local .ipa is written and no altool step is needed.
# (An altool upload step here would always fail: there is no .ipa file.)
#
# Usage: ./testflight.sh
set -euo pipefail
cd "$(dirname "$0")"

BUILD_DIR="build"

echo "==> Preflight (REL-231): clean tree + pushed commit required"
if [ -n "$(git status --porcelain)" ]; then
    echo "ABORT: working tree is not clean. Commit or stash changes first."
    exit 1
fi
git fetch origin main --quiet
HEAD_SHA="$(git rev-parse HEAD)"
ORIGIN_SHA="$(git rev-parse origin/main)"
if [ "$HEAD_SHA" != "$ORIGIN_SHA" ]; then
    echo "ABORT: HEAD ($HEAD_SHA) does not match origin/main ($ORIGIN_SHA). Push first."
    exit 1
fi
echo "    Provenance: uploading commit $HEAD_SHA"

echo "==> Archiving (Release)…"
xcodebuild -project VVCapture.xcodeproj -scheme VVCapture \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$BUILD_DIR/VVCapture.xcarchive" archive \
    -allowProvisioningUpdates

echo "==> Exporting (uploads to App Store Connect)…"
xcodebuild -exportArchive -archivePath "$BUILD_DIR/VVCapture.xcarchive" \
    -exportPath "$BUILD_DIR/export" -exportOptionsPlist ExportOptions.plist \
    -allowProvisioningUpdates

echo "Upload succeeded. The build appears in TestFlight after Apple processing (~10-30 min)."

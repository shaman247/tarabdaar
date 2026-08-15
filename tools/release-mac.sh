#!/bin/bash
# TarabdaarMac release build: archive → export → notarize → staple.
# Produces a notarized .app ready for direct distribution.
#
# Prereqs (one-time):
#   1. Apple Developer enrollment + Developer ID Application certificate
#      installed in Keychain Access.
#   2. `xcrun notarytool store-credentials tarabdaar-notary ...` (see
#      docs/packaging.md).
#   3. Fill in TEAM_ID and SIGN_IDENTITY below.
#
# Usage:
#   ./tools/release-mac.sh
# Output:
#   build/Release/Tarabdaar.app
set -euo pipefail
cd "$(dirname "$0")/.."

# ---- USER CONFIG ------------------------------------------------------------
TEAM_ID="WN86FWABN8"
SIGN_IDENTITY="Developer ID Application: YOUR NAME (${TEAM_ID})"
NOTARY_PROFILE="tarabdaar-notary"
# -----------------------------------------------------------------------------

BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/TarabdaarMac.xcarchive"
EXPORT_PATH="${BUILD_DIR}/Release"

rm -rf "${BUILD_DIR}"
mkdir -p "${EXPORT_PATH}"

# 1. Archive
echo "→ Archiving…"
xcodebuild -project Tarabdaar/Tarabdaar.xcodeproj \
    -scheme TarabdaarMac \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "${ARCHIVE_PATH}" \
    archive

# 2. Export to .app
echo "→ Exporting…"
cat > "${BUILD_DIR}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist"

APP_PATH="${EXPORT_PATH}/TarabdaarMac.app"

# 3. Zip for notarytool submission
echo "→ Notarizing…"
ZIP_PATH="${BUILD_DIR}/TarabdaarMac.zip"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

# 4. Staple the ticket onto the .app
echo "→ Stapling…"
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

echo "✅ Done: ${APP_PATH}"

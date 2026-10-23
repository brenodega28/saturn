#!/usr/bin/env bash
set -euo pipefail

: "${NOTARY_APPLE_ID:?}" "${NOTARY_TEAM_ID:?}" "${NOTARY_PASSWORD:?}"
: "${SPARKLE_PRIVATE_KEY:?}" "${SPARKLE_PUBLIC_ED_KEY:?}" "${SPARKLE_FEED_URL:?}" "${SPARKLE_DOWNLOAD_URL_PREFIX:?}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
DIST="$ROOT/dist"
ARCHIVE="$BUILD/Ensemble.xcarchive"
EXPORT="$BUILD/export"

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"
cd "$ROOT"

xcodegen generate

xcodebuild archive \
  -project Ensemble.xcodeproj \
  -scheme Ensemble \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD/DerivedData" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$NOTARY_TEAM_ID" \
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"

cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$NOTARY_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$BUILD/ExportOptions.plist"

APP="$EXPORT/Ensemble.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/Ensemble-$VERSION.dmg"

hdiutil create -volname Ensemble -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

xcrun notarytool submit "$DMG" \
  --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" \
  --wait
xcrun stapler staple "$DMG"

SPARKLE_BIN="$(find "$BUILD/DerivedData/SourcePackages/artifacts" -type d -path '*Sparkle/bin' | head -n 1)"
echo "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX" \
  "$DIST"

echo "Release ready in $DIST"

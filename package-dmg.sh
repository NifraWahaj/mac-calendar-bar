#!/bin/bash
# Packages dist/Calendar Bar.app into dist/CalendarBar-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/Calendar Bar.app"
[ -d "$APP" ] || { echo "Build it first: ./build-app.sh"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="dist/CalendarBar-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "Calendar Bar" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"

echo "==> Done: $DMG"
echo "    Unsigned builds show a Gatekeeper warning on other Macs. To distribute widely,"
echo "    sign with a Developer ID and notarize:"
echo "      codesign --force --deep --options runtime --timestamp -s \"Developer ID Application: NAME (TEAMID)\" \"$APP\""
echo "      xcrun notarytool submit \"$DMG\" --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PW --wait"
echo "      xcrun stapler staple \"$DMG\""

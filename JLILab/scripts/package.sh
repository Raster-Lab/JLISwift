#!/usr/bin/env bash
#
# Build, Developer-ID sign, notarize, staple, and package JLILab as a DMG for
# direct distribution. Run from anywhere; resolves paths relative to itself.
#
# One-time prerequisites (need an Apple Developer account):
#   1. A "Developer ID Application" certificate in your login keychain.
#   2. Store notarization credentials once:
#        xcrun notarytool store-credentials JLILabNotary \
#            --apple-id "you@example.com" --team-id "TEAMID" \
#            --password "app-specific-password"
#   3. (If the .xcodeproj is stale) regenerate it:  cd JLILab && xcodegen generate
#
# Usage:
#   NOTARY_PROFILE=JLILabNotary ./scripts/package.sh
#
# Notes: the app uses the hardened runtime (set in project.yml) and is not
# sandboxed, so it can read user-selected files and shell out to butteraugli /
# cjpeg for the cross-codec lab — both allowed under hardened runtime.
set -euo pipefail

cd "$(dirname "$0")/.."                       # → JLILab/
PROJECT="JLILab.xcodeproj"
SCHEME="JLILab"
NOTARY_PROFILE="${NOTARY_PROFILE:-JLILabNotary}"
BUILD="$(mktemp -d)"
ARCHIVE="$BUILD/JLILab.xcarchive"
EXPORT="$BUILD/export"
DMG="JLILab.dmg"

echo "▸ Archiving (Release)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" archive

echo "▸ Exporting (Developer ID)…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "scripts/ExportOptions.plist" -exportPath "$EXPORT"

APP="$EXPORT/JLILab.app"

echo "▸ Notarizing (profile: $NOTARY_PROFILE)…"
ZIP="$BUILD/JLILab.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ Stapling…"
xcrun stapler staple "$APP"

echo "▸ Building DMG…"
rm -f "$DMG"
hdiutil create -volname "JLILab" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "✓ Done: $(pwd)/$DMG  (notarized + stapled)"

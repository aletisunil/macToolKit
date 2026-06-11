#!/bin/zsh
# Build, sign (Developer ID), notarize and staple a distributable
# macToolKit.zip and macToolKit.dmg.
#
# Usage: Scripts/release.sh [VERSION]   (e.g. Scripts/release.sh 1.2.0)
#
# Prereqs (one-time):
#   - "Developer ID Application" certificate in the login keychain
#   - notarytool credentials saved:
#       xcrun notarytool store-credentials macToolKit \
#         --apple-id <apple-id> --team-id 5432YAY2UX --password <app-specific-pw>
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="macToolKit"
NOTARY_PROFILE="${NOTARY_PROFILE:-macToolKit}"
TEAM_ID="5432YAY2UX"
VERSION="${1:-${VERSION:-1.0.0}}"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
APP="$ARCHIVE/Products/Applications/$APP_NAME.app"
ZIP="$BUILD_DIR/$APP_NAME.zip"
DMG="$BUILD_DIR/$APP_NAME.dmg"

rm -rf "$BUILD_DIR"
xcodegen generate

echo "==> Archiving $VERSION (Release, Developer ID, hardened runtime)"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
  -configuration Release -archivePath "$ARCHIVE" archive \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="$VERSION" | tail -2

echo "==> Notarizing app"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling app"
xcrun stapler staple "$APP"

# Re-zip so the distributed archive contains the stapled app.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Building DMG"
STAGE="$BUILD_DIR/dmg-root"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
if command -v create-dmg >/dev/null; then
  create-dmg --volname "$APP_NAME" \
    --window-size 540 380 --icon-size 128 \
    --icon "$APP_NAME.app" 140 180 --app-drop-link 400 180 \
    --hide-extension "$APP_NAME.app" \
    "$DMG" "$STAGE"
else
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi
codesign --force --sign "Developer ID Application" --timestamp "$DMG"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Gatekeeper check"
spctl -a -vv "$APP"
spctl -a -t open --context context:primary-signature -vv "$DMG"
echo "Done: $ZIP  $DMG"

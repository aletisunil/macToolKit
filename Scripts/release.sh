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
VERSION="${1:-${VERSION:-1.1.0}}"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
APP="$ARCHIVE/Products/Applications/$APP_NAME.app"
ZIP="$BUILD_DIR/$APP_NAME.zip"
DMG="$BUILD_DIR/$APP_NAME.dmg"
DERIVED="$BUILD_DIR/DerivedData"
# Sparkle compares CFBundleVersion, so every release needs a higher build
# number than the last; commit count is monotonic on the release branch.
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
REPO_URL="https://github.com/aletisunil/macToolKit"

rm -rf "$BUILD_DIR"
xcodegen generate

echo "==> Archiving $VERSION build $BUILD_NUMBER (Release, Developer ID, hardened runtime)"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
  -configuration Release -archivePath "$ARCHIVE" archive \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" | tail -2

echo "==> Notarizing app"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling app"
xcrun stapler staple "$APP"

# Re-zip so the distributed archive contains the stapled app.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Generating Sparkle appcast"
# generate_appcast ships in the resolved Sparkle package; signs the zip and
# writes appcast.xml next to it. CI supplies the EdDSA key via the
# SPARKLE_PRIVATE_KEY env var; locally it comes from the login keychain
# (created with: generate_keys --account macToolKit).
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
APPCAST_DIR="$BUILD_DIR/appcast"
mkdir -p "$APPCAST_DIR"
cp "$ZIP" "$APPCAST_DIR/"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
    --link "$REPO_URL" \
    -o "$BUILD_DIR/appcast.xml" "$APPCAST_DIR"
else
  "$SPARKLE_BIN/generate_appcast" \
    --account macToolKit \
    --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
    --link "$REPO_URL" \
    -o "$BUILD_DIR/appcast.xml" "$APPCAST_DIR"
fi

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
echo "Done: $ZIP  $DMG  $BUILD_DIR/appcast.xml"

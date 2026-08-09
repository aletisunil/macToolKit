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
VERSION="${1:-${VERSION:-2.3}}"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
APP="$ARCHIVE/Products/Applications/$APP_NAME.app"
ZIP="$BUILD_DIR/$APP_NAME.zip"
DMG="$BUILD_DIR/$APP_NAME.dmg"
DERIVED="$BUILD_DIR/DerivedData"
# Sparkle compares CFBundleVersion, so every release needs a higher build
# number than the last; commit count is monotonic on the release branch.
BUILD_NUMBER_EXPLICIT="${BUILD_NUMBER:-}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
REPO_URL="https://github.com/aletisunil/macToolKit"
APPCAST_URL="$REPO_URL/releases/latest/download/appcast.xml"

# Preflight, before the ten-minute archive: the two ways this pipeline ships a
# build Sparkle will refuse to offer, both of which fail silently otherwise.

# 1. Uncommitted work is not in `git rev-list --count HEAD`, so a release built
#    from a dirty tree reuses the previous build number. Only a derived number
#    can be wrong this way: an explicit BUILD_NUMBER is the caller's own answer.
if [[ -z "$BUILD_NUMBER_EXPLICIT" && -n "$(git status --porcelain)" \
      && -z "${ALLOW_DIRTY:-}" ]]; then
  echo "FAIL: working tree is dirty, so build number $BUILD_NUMBER does not" >&2
  echo "      count this work. Commit first, or set ALLOW_DIRTY=1." >&2
  git status --short >&2
  exit 1
fi

# 2. Sparkle upgrades on CFBundleVersion alone, and a number that merely ties
#    the published one is indistinguishable from no update at all: no error
#    anywhere, users just never get offered it. Ask the live appcast.
if [[ -z "${SKIP_BUILD_NUMBER_CHECK:-}" ]]; then
  # `|| true`: the feed 404s until the first Sparkle-era release, and under
  # `set -e -o pipefail` a failed curl would otherwise abort the release.
  PUBLISHED=$(curl -fsSL --max-time 30 "$APPCAST_URL" 2>/dev/null |
    sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<\/sparkle:version>.*/\1/p' |
    sort -n | tail -1 || true)
  if [[ -z "$PUBLISHED" ]]; then
    echo "==> No published appcast reachable - skipping build-number check"
  elif (( BUILD_NUMBER <= PUBLISHED )); then
    echo "FAIL: build number $BUILD_NUMBER is not newer than the published" >&2
    echo "      $PUBLISHED, so Sparkle would never offer this update." >&2
    echo "      Commit at least $((PUBLISHED - BUILD_NUMBER + 1)) more change(s)," >&2
    echo "      or override with BUILD_NUMBER=$((PUBLISHED + 1))." >&2
    exit 1
  else
    echo "==> Build number $BUILD_NUMBER supersedes published $PUBLISHED"
  fi
fi

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

echo "==> Re-signing Sparkle nested components"
# The SPM Sparkle artifact ships Autoupdate, Updater.app and the XPC
# services signed by the Sparkle project; xcodebuild re-signs only the
# framework wrapper. Notarization rejects any Mach-O without our
# Developer ID + secure timestamp, so sign innermost-out, then re-sign
# the app because the framework's seal changed.
IDENTITY="Developer ID Application"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
for NESTED in \
  "XPCServices/Downloader.xpc" \
  "XPCServices/Installer.xpc" \
  "Autoupdate" \
  "Updater.app"; do
  [[ -e "$SPARKLE_FW/Versions/B/$NESTED" ]] || continue
  codesign --force --options runtime --timestamp \
    --preserve-metadata=entitlements \
    --sign "$IDENTITY" "$SPARKLE_FW/Versions/B/$NESTED"
done
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$SPARKLE_FW"
# --preserve-metadata=entitlements, not --entitlements: the checked-in
# .entitlements file holds the literal `$(APP_GROUP_ID)`, and codesign does no
# build-setting substitution. Passing it here overwrites the expanded .xcent
# Xcode already sealed in, leaving the app out of its own App Group - Peek
# settings then stop reaching the extension and the uninstaller's group
# container lookup returns nil.
codesign --force --options runtime --timestamp \
  --preserve-metadata=entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Verifying entitlements"
# Cheap guard against the above regressing: an unexpanded build setting or a
# mismatched group would ship silently, since neither notarization nor
# Gatekeeper cares what the group id says.
#
# The built app's Info.plist is the reference rather than a literal repeated
# here: `AppGroupIdentifier` is the value PeekDefaults looks up at runtime, so
# it is the one every other copy has to agree with.
APPEX="$APP/Contents/PlugIns/Peek.appex"
EXPECTED_GROUP=$(plutil -extract AppGroupIdentifier raw -o - \
  "$APP/Contents/Info.plist" 2>/dev/null || true)
if [[ "$EXPECTED_GROUP" != "$TEAM_ID."* ]]; then
  echo "FAIL: app Info.plist AppGroupIdentifier is '$EXPECTED_GROUP'," >&2
  echo "      expected a group prefixed with $TEAM_ID." >&2
  exit 1
fi

for BUNDLE in "$APP" "$APPEX"; do
  ENTS=$(codesign -d --entitlements - --xml "$BUNDLE" 2>/dev/null || true)
  if [[ "$ENTS" == *'$('* ]]; then
    echo "FAIL: $BUNDLE carries an unexpanded build setting:" >&2
    echo "$ENTS" >&2
    exit 1
  fi
  # Two copies to check per bundle: the Info.plist key the code reads and the
  # entitlement the sandbox grants. plutil splits key paths on dots, so the
  # entitlement key's own dots need escaping; `|| true` on both so a missing
  # key reports which bundle below instead of aborting on plutil's own error.
  DECLARED=$(plutil -extract AppGroupIdentifier raw -o - \
    "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)
  GRANTED=$(printf '%s' "$ENTS" |
    plutil -extract 'com\.apple\.security\.application-groups.0' raw -o - - \
    2>/dev/null || true)
  for ACTUAL in "$DECLARED" "$GRANTED"; do
    if [[ "$ACTUAL" != "$EXPECTED_GROUP" ]]; then
      echo "FAIL: $BUNDLE app group is '$ACTUAL', expected '$EXPECTED_GROUP'" >&2
      exit 1
    fi
  done
done
echo "    app group $EXPECTED_GROUP on app and Peek.appex"

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

#!/usr/bin/env bash
#
# VibeCoder — release.sh
#
# Cuts a signed, notarised DMG (no Sparkle). Publish via GitHub Releases
# or any static host you choose.
#
# Usage:
#   ./Release/release.sh <version>      e.g.  ./Release/release.sh 1.0.6
#
# Env overrides:
#   VIBECODER_NOTARY_PROFILE  default: VibeCoder-Notary
#   VIBECODER_TEAM_ID         optional; used only for messaging
#   VIBECODER_ALLOW_DIRTY=1   skip clean-tree check
#   VIBECODER_SKIP_NOTARY=1   archive + DMG only (unsigned smoke path not recommended)
#

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>   e.g.  $0 1.0.6"
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Version must be semver (e.g. 1.0.6). Got: $VERSION"
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="VibeCoder"
SCHEME="VibeCoder"
NOTARY_PROFILE="${VIBECODER_NOTARY_PROFILE:-VibeCoder-Notary}"
TEAM_ID="${VIBECODER_TEAM_ID:-}"

INFO_PLIST="$PROJECT_DIR/App/Info.plist"
EXPORT_PLIST="$PROJECT_DIR/Release/ExportOptions.plist"
BUILD_DIR="$PROJECT_DIR/Release/build"
ARCHIVE_PATH="$BUILD_DIR/VibeCoder-${VERSION}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export-${VERSION}"
DMG_PATH="$BUILD_DIR/VibeCoder-${VERSION}.dmg"
ZIP_PATH="$BUILD_DIR/VibeCoder-${VERSION}.zip"
APP_PATH=""

mkdir -p "$BUILD_DIR"

echo "▶ Validating prerequisites…"

if [[ "${VIBECODER_ALLOW_DIRTY:-0}" != "1" ]]; then
  if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)" ]]; then
    echo "❌ Working tree has uncommitted changes. Commit first or set VIBECODER_ALLOW_DIRTY=1."
    exit 1
  fi
fi

if [[ ! -f "$PROJECT_DIR/App/VibeCoder.xcodeproj/project.pbxproj" ]]; then
  echo "▶ Generating Xcode project…"
  (cd "$PROJECT_DIR" && xcodegen generate --spec App/project.yml)
fi

if ! security find-identity -p codesigning -v | grep -q "Developer ID Application"; then
  echo "⚠️  No Developer ID Application identity found — archive may fail codesign."
fi

# Bump marketing version in Info.plist when present as open keys
if [[ -f "$INFO_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$INFO_PLIST" 2>/dev/null \
    || true
  BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "0")
  if [[ "$BUILD_NUM" =~ ^[0-9]+$ ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD_NUM + 1))" "$INFO_PLIST" 2>/dev/null || true
  fi
fi

echo "▶ Archiving $SCHEME…"
xcodebuild archive \
  -project "$PROJECT_DIR/App/VibeCoder.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  | xcpretty 2>/dev/null || xcodebuild archive \
  -project "$PROJECT_DIR/App/VibeCoder.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS"

echo "▶ Exporting Developer ID app…"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST"

APP_PATH="$(find "$EXPORT_DIR" -maxdepth 2 -name "${APP_NAME}.app" | head -1)"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "❌ Could not find ${APP_NAME}.app under $EXPORT_DIR"
  exit 1
fi

if [[ "${VIBECODER_SKIP_NOTARY:-0}" != "1" ]]; then
  echo "▶ Zipping for notarisation…"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

  echo "▶ Submitting to notarytool (profile: $NOTARY_PROFILE)…"
  xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "▶ Stapling…"
  xcrun stapler staple "$APP_PATH"
else
  echo "⚠️  Skipping notarisation (VIBECODER_SKIP_NOTARY=1)"
fi

echo "▶ Building DMG…"
rm -f "$DMG_PATH"
STAGE="$BUILD_DIR/dmg-stage-${VERSION}"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGE"

echo ""
echo "✅ Release artifacts"
echo "   App: $APP_PATH"
echo "   DMG: $DMG_PATH"
echo ""
echo "Publish example:"
echo "  gh release create \"v${VERSION}\" \"$DMG_PATH\" --title \"VibeCoder ${VERSION}\""
if [[ -n "$TEAM_ID" ]]; then
  echo "   Team: $TEAM_ID"
fi

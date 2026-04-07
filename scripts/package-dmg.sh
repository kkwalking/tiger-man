#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/TigerMan.xcodeproj"
SCHEME_NAME="TigerMan"
APP_NAME="TigerMan"
CONFIGURATION="${CONFIGURATION:-Release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "error: missing project at $PROJECT_PATH" >&2
  exit 1
fi

for tool in xcodebuild hdiutil rsync; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool not found: $tool" >&2
    exit 1
  fi
done

MARKETING_VERSION="$(
  /usr/bin/awk -F' = ' '
    /MARKETING_VERSION = / {
      gsub(/;/, "", $2)
      print $2
      exit
    }
  ' "$ROOT_DIR/TigerMan.xcodeproj/project.pbxproj"
)"

if [[ -z "$MARKETING_VERSION" ]]; then
  MARKETING_VERSION="0.0.0"
fi

BUILD_ROOT="$(mktemp -d "/tmp/tigerman-package-build.XXXXXX")"
DMG_ROOT="$(mktemp -d "/tmp/tigerman-package-root.XXXXXX")"
HOME_DIR="$BUILD_ROOT/home"
OBJROOT="$BUILD_ROOT/obj"
SYMROOT="$BUILD_ROOT/sym"
PRECOMP_DIR="$BUILD_ROOT/precomp"
CLANG_CACHE="$BUILD_ROOT/clang-module-cache"
MODULE_CACHE="$BUILD_ROOT/module-cache"
SDK_CACHE="$BUILD_ROOT/sdk-stat-cache"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
APP_PATH="$SYMROOT/$CONFIGURATION/$APP_NAME.app"
DMG_PATH="$OUTPUT_DIR/$APP_NAME-$MARKETING_VERSION-unsigned.dmg"

cleanup() {
  rm -rf "$BUILD_ROOT" "$DMG_ROOT"
}
trap cleanup EXIT

mkdir -p \
  "$OUTPUT_DIR" \
  "$HOME_DIR" \
  "$OBJROOT" \
  "$SYMROOT" \
  "$PRECOMP_DIR" \
  "$CLANG_CACHE" \
  "$MODULE_CACHE" \
  "$SDK_CACHE" \
  "$DERIVED_DATA"

echo "==> Building $SCHEME_NAME ($CONFIGURATION) -> $APP_NAME.app"
HOME="$HOME_DIR" xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  OBJROOT="$OBJROOT" \
  SYMROOT="$SYMROOT" \
  SHARED_PRECOMPS_DIR="$PRECOMP_DIR" \
  CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" \
  MODULE_CACHE_DIR="$MODULE_CACHE" \
  SDK_STAT_CACHE_DIR="$SDK_CACHE" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app bundle not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Preparing DMG payload"
rsync -a "$APP_PATH" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
rm -f "$DMG_PATH"

echo "==> Creating DMG"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Created: $DMG_PATH"
echo "Note: this DMG is unsigned and not notarized. Target Macs may require manual Gatekeeper approval."

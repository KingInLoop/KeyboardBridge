#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DIST_DIR="$SCRIPT_DIR/dist"
APP_DIR="$DIST_DIR/KeyboardBridge.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
mkdir -p "$DIST_DIR"
BUILD_DIR=$(mktemp -d "$DIST_DIR/build.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RESOURCES_DIR"

ICON_SOURCE="$SCRIPT_DIR/assets/app-icon-master.png"
ICONSET_DIR="$BUILD_DIR/KeyboardBridge.iconset"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Missing icon source: $ICON_SOURCE" >&2
  exit 1
fi

mkdir -p "$ICONSET_DIR"
for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  filename="${spec#* }"
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/$filename" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/KeyboardBridge.icns"

for arch in arm64 x86_64; do
  swiftc \
    -target "$arch-apple-macosx13.0" \
    -O \
    -framework AppKit \
    -framework ApplicationServices \
    "$SCRIPT_DIR/KeyboardBridge.swift" \
    -o "$BUILD_DIR/KeyboardBridge-$arch"
done

lipo -create \
  "$BUILD_DIR/KeyboardBridge-arm64" \
  "$BUILD_DIR/KeyboardBridge-x86_64" \
  -output "$BIN_DIR/KeyboardBridge"

cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

SIGN_IDENTITY="${KEYBOARD_BRIDGE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | head -n 1 || true)
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing with: $SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  echo "No Developer ID certificate found; using ad-hoc signing for local testing."
  codesign --force --deep --sign - "$APP_DIR"
fi

"$BIN_DIR/KeyboardBridge" --self-test
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [[ -n "${KEYBOARD_BRIDGE_NOTARY_PROFILE:-}" ]]; then
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "Notarization requires a Developer ID Application certificate." >&2
    exit 1
  fi
  NOTARY_ZIP="$BUILD_DIR/KeyboardBridge-notarize.zip"
  ditto -c -k --keepParent "$APP_DIR" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$KEYBOARD_BRIDGE_NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
fi

echo "Built: $APP_DIR"

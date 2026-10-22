#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DIST_DIR="$SCRIPT_DIR/dist"
APP_DIR="$DIST_DIR/KeyboardBridge.app"

# Avoid encoding Finder/provenance metadata as AppleDouble `._*` files in the
# installer payload. Those files are unnecessary and can confuse diagnostics.
export COPYFILE_DISABLE=1

"$SCRIPT_DIR/build-macos.sh"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
FINAL_PKG="$DIST_DIR/KeyboardBridge-macOS-v$VERSION.pkg"
BUILD_DIR=$(mktemp -d "$DIST_DIR/installer.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT

PAYLOAD_ROOT="$BUILD_DIR/root"
SCRIPTS_DIR="$BUILD_DIR/scripts"
COMPONENT_PKG="$BUILD_DIR/KeyboardBridge-component.pkg"
mkdir -p "$PAYLOAD_ROOT/Applications" "$SCRIPTS_DIR"
ditto --noextattr --noqtn --norsrc "$APP_DIR" "$PAYLOAD_ROOT/Applications/KeyboardBridge.app"
cp "$SCRIPT_DIR/installer-scripts/preinstall" "$SCRIPTS_DIR/preinstall"
cp "$SCRIPT_DIR/installer-scripts/postinstall" "$SCRIPTS_DIR/postinstall"
/usr/bin/xattr -cr "$PAYLOAD_ROOT" "$SCRIPTS_DIR" 2>/dev/null || true

chmod +x "$SCRIPTS_DIR/preinstall" "$SCRIPTS_DIR/postinstall"

pkgbuild \
  --root "$PAYLOAD_ROOT" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "local.keyboardbridge.installer" \
  --version "$VERSION" \
  --install-location "/" \
  --ownership recommended \
  "$COMPONENT_PKG"

INSTALLER_IDENTITY="${KEYBOARD_BRIDGE_INSTALLER_IDENTITY:-}"
if [[ -z "$INSTALLER_IDENTITY" ]]; then
  INSTALLER_IDENTITY=$(security find-identity -v -p basic 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Installer:[^"]*\)".*/\1/p' \
    | head -n 1 || true)
fi

if [[ -n "$INSTALLER_IDENTITY" ]]; then
  echo "Signing installer with: $INSTALLER_IDENTITY"
  productbuild --package "$COMPONENT_PKG" --sign "$INSTALLER_IDENTITY" "$FINAL_PKG"
else
  echo "No Developer ID Installer certificate found; creating an unsigned installer for local testing."
  productbuild --package "$COMPONENT_PKG" "$FINAL_PKG"
fi

pkgutil --payload-files "$FINAL_PKG" | grep -q '^./Applications/KeyboardBridge.app/'

if [[ -n "${KEYBOARD_BRIDGE_NOTARY_PROFILE:-}" ]]; then
  if [[ -z "$INSTALLER_IDENTITY" ]]; then
    echo "Installer notarization requires a Developer ID Installer certificate." >&2
    exit 1
  fi
  xcrun notarytool submit "$FINAL_PKG" \
    --keychain-profile "$KEYBOARD_BRIDGE_NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$FINAL_PKG"
  xcrun stapler validate "$FINAL_PKG"
fi

echo "Built installer: $FINAL_PKG"

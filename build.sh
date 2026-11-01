#!/bin/bash
# Builds Custom Notch, signs it, installs it to ~/Applications and (re)launches it.
#   ./build.sh              build, install, launch
#   ./build.sh --no-launch  build and install only
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Custom Notch"
EXECUTABLE="CustomNotch"
BUNDLE_ID="local.customnotch.CustomNotch"
VERSION="0.1.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
INSTALL_DIR="$HOME/Applications"
CERT_NAME="Custom Notch Local Signing"

LAUNCH=1
[[ "${1:-}" == "--no-launch" ]] && LAUNCH=0

# If Xcode is selected but not ready (still installing, or its license not accepted yet), build with the
# Command Line Tools for this run only. Nothing is changed system-wide.
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! swift --version >/dev/null 2>&1 && [[ -d /Library/Developer/CommandLineTools ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    echo "    (Xcode isn't ready yet: using the Command Line Tools)"
fi

echo "==> Compiling (release)"
swift build -c release --product "$EXECUTABLE"
swift build -c release --product notch-hook
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/$APP_NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$BIN_DIR/notch-hook" "$APP/Contents/Helpers/notch-hook"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"

# A stable certificate keeps macOS permissions across rebuilds; an ad-hoc
# signature changes with every build, so macOS asks for permissions again.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$SIGN_IDENTITY"
elif security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    IDENTITY="$CERT_NAME"
else
    IDENTITY="-"
    echo "    (ad-hoc signature: run scripts/make-signing-cert.sh once to keep permissions between builds)"
fi
echo "==> Signing with: $IDENTITY"
# Sign the helper first, then the app around it.
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.hook" "$APP/Contents/Helpers/notch-hook"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"

echo "==> Installing to $INSTALL_DIR"
pkill -x "$EXECUTABLE" 2>/dev/null && sleep 0.5 || true
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"

if [[ $LAUNCH == 1 ]]; then
    echo "==> Launching"
    open "$INSTALL_DIR/$APP_NAME.app"
fi
echo "Done."

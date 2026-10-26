#!/bin/bash
# Builds build/Relaunch.app. Needs only the Xcode Command Line Tools.
#   scripts/build.sh            # native arch
#   scripts/build.sh --install  # also copy to /Applications
#
# Signing for distribution (optional; without it the app is signed ad hoc,
# which is fine on your own Mac but Gatekeeper blocks it on others):
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#       sign with the hardened runtime and a secure timestamp
#   NOTARY_PROFILE=relaunch
#       also notarize and staple. Create the profile once with
#       xcrun notarytool store-credentials relaunch --apple-id <email> --team-id <TEAMID>
#   Produces build/Relaunch.zip, ready to upload.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ] && [ -z "$SIGN_IDENTITY" ]; then
  echo "NOTARY_PROFILE needs SIGN_IDENTITY (a Developer ID Application certificate)" >&2
  exit 1
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP=build/Relaunch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Relaunch" "$APP/Contents/MacOS/Relaunch"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ] || [ scripts/make_icon.swift -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign inside out: Sparkle's helpers, then the framework, then the app.
# No entitlements needed: no JIT, no unsigned libraries, not sandboxed.
if [ -n "$SIGN_IDENTITY" ]; then
  sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }
else
  sign() { codesign --force --sign - "$@"; }
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP"

if [ -n "$NOTARY_PROFILE" ]; then
  ZIP=build/Relaunch.zip
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  # Re-zip so the download carries the stapled ticket.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose=2 "$APP"
  echo "Notarized $ZIP"
fi

if [ "${1:-}" = "--install" ]; then
  pkill -x Relaunch 2>/dev/null || true
  rm -rf /Applications/Relaunch.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Relaunch.app"
fi

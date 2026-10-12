#!/bin/bash
# Builds Relaunch.app and packages it into dist/ for a release:
#   Relaunch.dmg  (drag-to-Applications disk image)
#   Relaunch.zip  (used by the install script)
#   *.sha256      (checksums the install script verifies)
#
# With SIGN_IDENTITY and NOTARY_PROFILE set (see scripts/build.sh), the app
# and the DMG are both signed with Developer ID and notarized, so macOS opens
# them without the "could not verify … free of malware" warning.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh

rm -rf dist
mkdir -p dist/dmg
ditto -c -k --keepParent build/Relaunch.app dist/Relaunch.zip

cp -R build/Relaunch.app dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname Relaunch -srcfolder dist/dmg -ov -format UDZO -quiet dist/Relaunch.dmg
rm -rf dist/dmg

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" dist/Relaunch.dmg
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit dist/Relaunch.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple dist/Relaunch.dmg
  spctl --assess --type open --context context:primary-signature -v dist/Relaunch.dmg
fi

cd dist
for f in Relaunch.zip Relaunch.dmg; do shasum -a 256 "$f" > "$f.sha256"; done
ls -lh

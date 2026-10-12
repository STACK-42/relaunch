#!/bin/bash
# Builds Relaunch.app and packages it into dist/ for a release:
#   Relaunch.dmg  (drag-to-Applications disk image)
#   Relaunch.zip  (used by the install script)
#   *.sha256      (checksums the install script verifies)
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

cd dist
for f in Relaunch.zip Relaunch.dmg; do shasum -a 256 "$f" > "$f.sha256"; done
ls -lh

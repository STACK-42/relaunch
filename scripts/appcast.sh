#!/bin/bash
# Writes dist/appcast.xml, the feed the app's updater (Sparkle) reads. It
# lists only the release being made; the app finds it through
# releases/latest/download/appcast.xml, so publishing a release updates the
# feed. Run after scripts/package.sh:
#   scripts/appcast.sh v1.2.0
#
# The zip is signed with Sparkle's EdDSA key: from SPARKLE_PRIVATE_KEY when
# set (CI), otherwise from the "relaunch" account in your login keychain.
# The app only installs updates signed by the key matching SUPublicEDKey in
# Resources/Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/appcast.sh <tag>}"
REPO="STACK-42/relaunch"
SIGN_UPDATE=.build/artifacts/sparkle/Sparkle/bin/sign_update
PLIST=build/Relaunch.app/Contents/Info.plist

VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
MIN_OS="$(plutil -extract LSMinimumSystemVersion raw "$PLIST")"

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  ENCLOSURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - dist/Relaunch.zip)"
else
  ENCLOSURE="$("$SIGN_UPDATE" --account relaunch dist/Relaunch.zip)"
fi

cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Relaunch</title>
    <item>
      <title>Relaunch $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Relaunch.zip"
                 type="application/octet-stream" $ENCLOSURE />
    </item>
  </channel>
</rss>
EOF
echo "Wrote dist/appcast.xml for $VERSION ($BUILD)"

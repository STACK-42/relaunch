#!/bin/bash
# Renders scripts/og/og.html to website/assets/og.png, the 1200×630 image
# shown when the site is shared (Open Graph / Twitter card). Needs Google Chrome.
# Renders at 2× and downsamples, which gives crisper text than a 1× render.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Google Chrome not found (set CHROME=/path/to/chrome)" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
  --window-size=1200,630 --screenshot="$tmp/og@2x.png" \
  "file://$PWD/scripts/og/og.html" >/dev/null 2>&1

sips -z 630 1200 "$tmp/og@2x.png" --out website/assets/og.png >/dev/null
echo "Wrote website/assets/og.png ($(sips -g pixelWidth -g pixelHeight website/assets/og.png | awk '/pixel/{printf "%s ", $2}'))"

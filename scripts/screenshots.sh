#!/bin/sh
# Regenerate the README screenshots from the synthetic demo (dashboard/index.html#demo).
# Runs on a development machine with Google Chrome (or Chromium) and ImageMagick.
# No real data is involved: the demo is generated inside the page.
#
#   sh scripts/screenshots.sh
#   CHROME=/path/to/chrome sh scripts/screenshots.sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
out="$root/docs/images"
mkdir -p "$out"

chrome=${CHROME:-}
if [ -z "$chrome" ]; then
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" google-chrome chromium chromium-browser; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then chrome=$c; break; fi
  done
fi
[ -n "$chrome" ] || { echo 'Chrome/Chromium not found (set CHROME=)' >&2; exit 2; }
command -v magick >/dev/null 2>&1 || { echo 'ImageMagick (magick) not found' >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
base="file://$root/dashboard/index.html#demo&theme=light&tz=Asia/Tokyo"

shot() { # shot LANG WIDTH HEIGHT FILE
  # Language and theme come from the URL fragment, so the OS locale and dark mode do not matter.
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --no-first-run \
    --user-data-dir="$tmp/profile-$1-$3" --window-size="$2,$3" \
    --virtual-time-budget=5000 --screenshot="$4" "$base&lang=$1" >/dev/null 2>&1
}
compress() { magick "$1" -strip -define png:compression-level=9 -dither None -colors 256 "PNG8:$2"; }

# Overview: header, KPIs, leak tracking and the first two chart rows.
shot ja 1280 1820 "$tmp/ja.png"
compress "$tmp/ja.png" "$out/dashboard-demo-ja.png"
shot en 1280 1820 "$tmp/en.png"
compress "$tmp/en.png" "$out/dashboard-demo-en.png"

# Weekday x hour heatmap, cropped from a full-page capture.
shot ja 1280 3400 "$tmp/full.png"
magick "$tmp/full.png" -crop 1280x340+0+1722 +repage "$tmp/heat.png"
compress "$tmp/heat.png" "$out/dashboard-heatmap-ja.png"

ls -l "$out"

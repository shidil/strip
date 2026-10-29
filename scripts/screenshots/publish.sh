#!/usr/bin/env bash
# Turns raw VM captures (.build/screenshots/raw/*.png, from capture.sh) into the committed web images
# in site/assets/img/screenshots/. The README links the same files, so the site and README never
# drift apart.
#
#   scripts/screenshots/publish.sh              # the shots the site and README use
#   scripts/screenshots/publish.sh search-peek  # any other raw capture, by name
#
# Two framings, because the VM display is a 3440×1440 ultrawide:
#   layout shots (strip, monocle, pinned)  the whole display — the width IS the point — 2400px wide
#   UI shots (overview, search*, help)     a centered 16:9 crop, 1600×900pt: these panels keep their
#                                          size on any display, so the full frame would leave them tiny
# Print each file's size and update the width/height attributes in site/index.html if they change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RAW_DIR="$ROOT/.build/screenshots/raw"
DEST="$ROOT/site/assets/img/screenshots"
QUALITY=82
CROP_HEIGHT_FRACTION="0.625" # 900pt of the display's 1440pt; width follows at 16:9

mkdir -p "$DEST"
if [ $# -gt 0 ]; then names=("$@"); else names=(strip monocle pinned overview search help); fi
for name in "${names[@]}"; do
  src="$RAW_DIR/$name.png"
  out="$DEST/$name.jpg"
  [ -f "$src" ] || { echo "✗ no raw capture $src (run capture.sh)" >&2; exit 1; }
  case "$name" in
    overview|search*|help)
      h=$(sips -g pixelHeight "$src" | awk '/pixelHeight/ {print $2}')
      ch=$(awk -v h="$h" -v f="$CROP_HEIGHT_FRACTION" 'BEGIN { printf "%d", h * f }')
      cw=$(( ch * 16 / 9 ))
      # sips -c crops around the image center, where these panels sit.
      sips -c "$ch" "$cw" "$src" --out "$RAW_DIR/.crop-$name.png" >/dev/null
      src="$RAW_DIR/.crop-$name.png"
      width=2000
      ;;
    *) width=2400 ;;
  esac
  sips -s format jpeg -s formatOptions "$QUALITY" --resampleWidth "$width" "$src" --out "$out" >/dev/null
  dims=$(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/ {print $2}' | paste -sd x -)
  echo "  ✓ ${out#"$ROOT"/} ($dims, $(( $(stat -f %z "$out") / 1024 )) KB)"
done
rm -f "$RAW_DIR"/.crop-*.png

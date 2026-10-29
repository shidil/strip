#!/usr/bin/env bash
# Turns raw VM captures (.build/screenshots/raw/*.png, from capture.sh) into the committed web images:
# site/assets/img/screenshots/<shot>.jpg, 2000px wide. The README links the same files, so the site
# and README never drift apart.
#
#   scripts/screenshots/publish.sh              # the shots the site and README use
#   scripts/screenshots/publish.sh search-peek  # any other raw capture, by name
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RAW_DIR="$ROOT/.build/screenshots/raw"
DEST="$ROOT/site/assets/img/screenshots"
WIDTH=2000    # index.html declares width="2000" height="1255" for a 16:10-ish VM display
QUALITY=82

mkdir -p "$DEST"
if [ $# -gt 0 ]; then names=("$@"); else names=(strip overview search help); fi
for name in "${names[@]}"; do
  src="$RAW_DIR/$name.png"
  [ -f "$src" ] || { echo "✗ no raw capture $src (run capture.sh)" >&2; exit 1; }
  sips -s format jpeg -s formatOptions "$QUALITY" --resampleWidth "$WIDTH" "$src" --out "$DEST/$name.jpg" >/dev/null
  dims=$(sips -g pixelWidth -g pixelHeight "$DEST/$name.jpg" | awk '/pixel/ {print $2}' | paste -sd x -)
  echo "  ✓ ${DEST#"$ROOT"/}/$name.jpg ($dims, $(( $(stat -f %z "$DEST/$name.jpg") / 1024 )) KB)"
done

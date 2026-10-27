#!/usr/bin/env bash
# Regenerate the website's raster images from their SVG sources. Needs Google Chrome.
#
#   site/assets/img/og-image.png          1200×630 social card  ← docs/assets/strip-banner.svg
#   site/assets/img/apple-touch-icon.png  180×180 home-screen icon ← site/assets/img/favicon.svg
#
# Run after editing either SVG:  scripts/site/render-images.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -x "$CHROME" ]] || { echo "Google Chrome not found; set CHROME=/path/to/chrome" >&2; exit 1; }

# render <html file> <width> <height> <output png>
# Headless Chrome writes the screenshot but doesn't always exit, so wait for the file instead.
render() {
  local html="$1" width="$2" height="$3" out="$4"
  rm -f "$out"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --user-data-dir="$WORK/profile" --window-size="$width,$height" \
    --screenshot="$out" "file://$html" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 150); do
    [[ -s "$out" ]] && break
    sleep 0.2
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [[ -s "$out" ]] || { echo "failed to render $out" >&2; exit 1; }
  echo "wrote ${out#"$ROOT"/}"
}

# Social card: the banner's first frame along the top edge (so its glow meets the edge, not a
# seam), with a caption underneath.
cat > "$WORK/og.html" <<EOF
<!doctype html>
<style>
  html, body { margin: 0; width: 1200px; height: 630px; overflow: hidden; background: #0b0b11; }
  body { display: grid; grid-template-rows: auto 1fr; }
  img { display: block; width: 1200px; }
  p {
    margin: 0; place-self: center;
    color: #6a6a76; font: 500 22px -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
  }
  b { color: #cfcfd8; font-weight: 600; }
</style>
<img src="file://$ROOT/docs/assets/strip-banner.svg" alt="">
<p><b>Open source</b> · macOS 14+ · github.com/shidil/strip</p>
EOF
render "$WORK/og.html" 1200 630 "$ROOT/site/assets/img/og-image.png"

# Touch icon: iOS rounds the corners itself, so fill the square edge to edge.
cat > "$WORK/icon.html" <<EOF
<!doctype html>
<style>
  html, body { margin: 0; width: 180px; height: 180px; overflow: hidden;
    background: linear-gradient(135deg, #9cc0ff, #b58cf2); }
  img { display: block; width: 210px; height: 210px; margin: -15px; }
</style>
<img src="file://$ROOT/site/assets/img/favicon.svg" alt="">
EOF
render "$WORK/icon.html" 180 180 "$ROOT/site/assets/img/apple-touch-icon.png"

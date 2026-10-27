#!/usr/bin/env bash
# Screenshots of the website, one viewport per section, at desktop and phone sizes, for checking a
# copy or layout change by eye before pushing. Needs Google Chrome. Output goes to
# .build/site-preview/<width>-<section>.png (not committed).
#
#   scripts/site/preview.sh                       # every section, 1440×1100 and 390×844
#   scripts/site/preview.sh search features       # only these sections (ids in index.html; "top" = hero)
#   WIDTHS="1024x800" scripts/site/preview.sh     # other viewport sizes
#   SCENE=6 scripts/site/preview.sh how-it-works  # the walkthrough on scene 6 (1-based)
#   VTIME=5500 …                                  # shoot later: ms of page time (a phase lasts 2300)
#
# The walkthrough player and the hero film are animated; a screenshot catches one moment of them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="$ROOT/.build/site-preview"
WORK="$(mktemp -d)"
# A copy of the page that hides every section above ?section=, so it renders at the top. (Headless
# Chrome's screenshot ignores scrolling, to a #hash or from script.) Lives next to index.html so its
# relative asset paths resolve.
PAGE="$ROOT/site/.preview.html"
trap 'rm -rf "$WORK" "$PAGE"' EXIT
# SCENE=n also opens the walkthrough on scene n (1-based) instead of the first. Transitions and
# animations are off: virtual time doesn't advance them, so a shot would catch them half-way.
sed "s#</head>#<style>*, *::before, *::after { transition: none !important; animation: none !important; }</style></head>#; s#</body>#<script>{ const id = new URLSearchParams(location.search).get('section'); let n = id \&\& document.getElementById(id); while (n \&\& (n = n.previousElementSibling)) n.style.display = 'none'; addEventListener('load', () => document.querySelectorAll('.player-controls__dot')[${SCENE:-1} - 1]?.click()); }</script></body>#" \
  "$ROOT/site/index.html" >"$PAGE"

[[ -x "$CHROME" ]] || { echo "Google Chrome not found; set CHROME=/path/to/chrome" >&2; exit 1; }
mkdir -p "$OUT"
sections=("$@"); [[ ${#sections[@]} -gt 0 ]] || sections=(top how-it-works search features keyboard get-started faq)
read -r -a sizes <<<"${WIDTHS:-1440x1100 390x844}"

for size in "${sizes[@]}"; do
  width="${size%x*}" height="${size#*x}"
  for section in "${sections[@]}"; do
    out="$OUT/$width-$section.png"
    url="file://$PAGE"; [[ "$section" == top ]] || url="$url?section=$section"
    # The page sits in an iframe of exactly width×height: headless Chrome won't make a window narrower
    # than ~500px, so a phone width needs the iframe to get a true phone-sized viewport.
    printf '<!doctype html><style>html,body{margin:0;background:#000}iframe{display:block;border:0}</style><iframe src="%s" width="%s" height="%s"></iframe>' \
      "$url" "$width" "$height" >"$WORK/frame.html"
    rm -f "$out"
    # Headless Chrome writes the screenshot but doesn't always exit, so wait for the file instead.
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
      --user-data-dir="$WORK/profile" --window-size="$(( width > 600 ? width : 600 )),$height" \
      --virtual-time-budget="${VTIME:-3000}" --allow-file-access-from-files \
      --screenshot="$out" "file://$WORK/frame.html" >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 150); do [[ -s "$out" ]] && break; sleep 0.2; done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [[ -s "$out" ]] || { echo "failed to render $out" >&2; exit 1; }
    echo "wrote ${out#"$ROOT"/}"
  done
done

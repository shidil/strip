#!/bin/bash
# GUEST side of scripts/screenshots/capture.sh: stages a believable desktop in the strip-e2e VM, drives
# Strip into each state worth showing, and screencaptures it. Runs inside a guest Terminal session
# (capture.sh starts it), because UI scripting and screencapture both need that Terminal's grants
# (Accessibility, Developer Tools, Screen Recording — scripts/e2e/vm/setup.sh step 7).
#
#   scene.sh <work dir> [shot ...]     # shots: strip monocle pinned overview search search-peek help
#                                      # (default: all)
#   SHOT_HEIGHT=0.90 scene.sh …        # window height (Strip's heightFraction; 0.05 steps, default 0.85)
#
# Writes <work dir>/out/<shot>.png (full-display Retina PNGs) and <work dir>/out/exitcode.
# Reuses the e2e driver/log helpers (scripts/e2e/lib) for hotkeys and for waiting on Strip's log.
set -uo pipefail

WORK="$1"; shift
SHOTS="${*:-strip monocle pinned overview search search-peek help}"
OUT="$WORK/out"
PAGES="$WORK/pages"
APP="$WORK/.build/Strip.app"
CHROME_PROFILE="/tmp/strip-shots-chrome-profile" # kept across runs: first-run UI stays dismissed
export STRIP_LOG="$WORK/strip.log"

# shellcheck source=../e2e/lib/log_assert.sh
source "$WORK/scripts/e2e/lib/log_assert.sh"
# shellcheck source=../e2e/lib/fixture.sh
source "$WORK/scripts/e2e/lib/fixture.sh"
# shellcheck source=../e2e/lib/driver.sh
source "$WORK/scripts/e2e/lib/driver.sh"

SCENE_APPS=(Preview Safari "Google Chrome")
fail() { echo "✗ $*" >&2; echo 1 >"$OUT/exitcode"; exit 1; }
shot() {
  screencapture -x -t png "$OUT/$1.png" || fail "screencapture $1 (does Terminal have Screen Recording?)"
  echo "  ✓ $1"
}
wants() { case " $SHOTS " in *" $1 "*) return 0 ;; esac; return 1; }

# Pages for the browser tabs. Local files: deterministic, no network, and the titles are what search
# ranks. "spring" matches one tab in each browser, so a single query shows cross-app tab results.
write_pages() {
  rm -rf "$PAGES"; mkdir -p "$PAGES"
  cat >"$PAGES/style.css" <<'EOF'
:root { color-scheme: light; --accent: #3b6fe0; }
body { margin: 0; font: 16px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; color: #1d1d22; background: #fbfbfd; }
header { padding: 56px 0 28px; background: linear-gradient(180deg, color-mix(in srgb, var(--accent) 14%, #fff), #fbfbfd); }
main, header > div { max-width: 760px; margin: 0 auto; padding: 0 32px; }
.kicker { color: var(--accent); font-weight: 700; font-size: 13px; letter-spacing: .08em; text-transform: uppercase; }
h1 { margin: 6px 0 8px; font-size: 38px; line-height: 1.15; letter-spacing: -.01em; }
.meta { color: #6b6b76; font-size: 14px; }
h2 { margin: 32px 0 8px; font-size: 21px; }
li { margin: 6px 0; }
.card { margin: 20px 0; padding: 16px 20px; border: 1px solid #e3e3ea; border-radius: 12px; background: #fff; }
table { width: 100%; border-collapse: collapse; margin: 12px 0; font-size: 15px; }
td, th { padding: 9px 10px; border-bottom: 1px solid #ececf2; text-align: left; }
th { color: #6b6b76; font-weight: 600; font-size: 13px; }
code { padding: 2px 6px; border-radius: 6px; background: #eef0f6; font: 14px ui-monospace, Menlo, monospace; }
EOF
  page() { # page <file> <accent> <kicker> <title> <meta> <body html>
    printf '<!doctype html><meta charset="utf-8"><title>%s</title><link rel="stylesheet" href="style.css">
<style>:root{--accent:%s}</style><header><div><p class="kicker">%s</p><h1>%s</h1><p class="meta">%s</p></div></header><main>%s</main>\n' \
      "$4" "$2" "$3" "$4" "$5" "$6" >"$PAGES/$1"
  }
  page release-checklist.html "#3b6fe0" "Project · v0.2" "Release checklist" "Updated this morning · 3 of 7 done" \
    '<div class="card"><table><tr><th>Step</th><th>Owner</th><th>Status</th></tr>
<tr><td>Freeze the changelog</td><td>Sam</td><td>Done</td></tr><tr><td>Run the full test suite</td><td>CI</td><td>Done</td></tr>
<tr><td>Update screenshots</td><td>Alex</td><td>Done</td></tr><tr><td>Notarize the build</td><td>Sam</td><td>In progress</td></tr>
<tr><td>Draft release notes</td><td>Priya</td><td>Not started</td></tr><tr><td>Tag and publish</td><td>Sam</td><td>Not started</td></tr></table></div>
<h2>Notes</h2><ul><li>Hold the tag until notarization comes back clean.</li><li>Release notes should lead with search.</li></ul>'
  page spring-tuning.html "#7a5ae0" "Engineering notes" "Spring tuning" "Damping, stiffness and how motion should feel" \
    '<p>Three presets cover almost everything: a crisp <code>track</code>, a lively <code>pop</code>, and a soft <code>glide</code>.</p>
<div class="card"><table><tr><th>Preset</th><th>Stiffness</th><th>Damping</th><th>Settles in</th></tr>
<tr><td>Track</td><td>420</td><td>38</td><td>~220 ms</td></tr><tr><td>Pop</td><td>520</td><td>30</td><td>~260 ms</td></tr>
<tr><td>Glide</td><td>180</td><td>26</td><td>~420 ms</td></tr></table></div>
<h2>Open questions</h2><ul><li>Should terminals snap instead of spring?</li><li>Per-display refresh rate: 60 vs 120 Hz.</li></ul>'
  page window-rules.html "#1f9d74" "Draft" "Window rules" "Which windows join the film, and which float" \
    '<ul><li>Standard, resizable windows join the film.</li><li>Dialogs, sheets and palettes float above it.</li>
<li>Tiny windows (under 20% of the display) are left alone.</li></ul><h2>Ideas</h2><ul><li>Per-app overrides in a config file.</li></ul>'
  page reading-list.html "#d9682b" "Saved for later" "Reading list" "12 articles · 3 unread" \
    '<div class="card"><b>The case for fixed focal points</b><p class="meta">Design essay · 9 min read</p></div>
<div class="card"><b>A short history of tiling window managers</b><p class="meta">Long read · 22 min</p></div>
<div class="card"><b>Keyboard-first interfaces, revisited</b><p class="meta">Article · 6 min read</p></div>'
  page spring-pancakes.html "#c2410c" "Recipes · weeknight" "Spring onion pancakes" "Serves 4 · 35 minutes" \
    '<h2>Ingredients</h2><ul><li>2 cups plain flour</li><li>¾ cup hot water</li><li>4 spring onions, finely sliced</li><li>Sesame oil and flaky salt</li></ul>
<h2>Method</h2><ol><li>Mix the flour and water into a soft dough; rest for 20 minutes.</li><li>Roll thin, brush with oil, scatter the onions, roll up and coil.</li><li>Flatten and pan-fry until crisp and golden.</li></ol>'
  page trail-map.html "#2f855a" "Weekend" "Coastal trail" "14 km loop · moderate · 4–5 hours" \
    '<div class="card"><table><tr><th>Section</th><th>Distance</th><th>Climb</th></tr><tr><td>Car park to lookout</td><td>3.2 km</td><td>180 m</td></tr>
<tr><td>Lookout to the beach</td><td>5.1 km</td><td>40 m</td></tr><tr><td>Beach loop back</td><td>5.7 km</td><td>210 m</td></tr></table></div>'
}

# stage <index> <process> <launcher> — opens one window and places it BEFORE Strip runs: sized past
# Strip's tiling threshold (20% of the display's width, 40% of its height), and stepped right by
# <index> because Strip lays out the windows it finds at launch in on-screen order — that's the film
# order. Never resize a window Strip already manages: it reads the size back and "learns" it as the
# app's minimum width.
stage() {
  local index="$1" app="$2" launcher="$3" w h
  "$launcher"
  for _ in $(seq 1 50); do
    osascript -e "tell application \"System Events\" to tell process \"$app\" to get name of window 1" >/dev/null 2>&1 && break
    sleep 0.2
  done
  sleep 0.5
  read -r w h <<<"$(_screen_size)"
  osascript -e "tell application \"System Events\" to tell process \"$app\"
    set position of window 1 to {$(( 20 + index * 90 )), $(( 60 + index * 40 ))}
    set size of window 1 to {$(( w * 55 / 100 )), $(( h * 6 / 10 ))}
  end tell" >/dev/null 2>&1 || fail "couldn't place the $app window"
}

launch_preview() { open -a Preview "$WORK/og-image.png"; }
launch_safari() {
  open -a Safari "$PAGES/reading-list.html" "$PAGES/spring-pancakes.html" "$PAGES/trail-map.html"
  sleep 2
  osascript -e 'tell application "Safari" to activate' \
    -e 'tell application "System Events" to tell process "Safari" to click menu item "Merge All Windows" of menu "Window" of menu bar 1' \
    >/dev/null 2>&1
}
launch_terminal() {
  # Live, real output that still reads in a narrow side slot.
  osascript -e 'tell application "Terminal" to do script "clear; top -o cpu -stats command,cpu,mem"' >/dev/null
}
launch_chrome() {
  open -na "Google Chrome" --args --no-first-run --no-default-browser-check \
    --disable-search-engine-choice-screen --user-data-dir="$CHROME_PROFILE" \
    "file://$PAGES/release-checklist.html" "file://$PAGES/spring-tuning.html" "file://$PAGES/window-rules.html"
  sleep 2
  # First tab active, so "spring" is a background tab: a tab result search can peek at.
  osascript -e 'tell application "Google Chrome" to activate' \
    -e 'tell application "System Events" to keystroke "1" using command down' >/dev/null 2>&1
}
launch_finder() {
  open /Applications
  sleep 1
  osascript -e 'tell application "Finder" to set current view of front window to icon view' >/dev/null 2>&1
}

teardown() {
  for app in "${SCENE_APPS[@]}"; do
    osascript -e "tell application \"$app\" to if it is running then quit" >/dev/null 2>&1
  done
  osascript -e 'tell application "Finder" to close every window' >/dev/null 2>&1
  pkill -x top 2>/dev/null
  pkill -x Strip 2>/dev/null
}

mkdir -p "$OUT"; rm -f "$OUT"/*.png "$OUT/exitcode"
echo "=== Strip screenshots: $SHOTS ==="

# Clean slate: no Strip, no scene apps, no stray Finder windows, default settings (bottom rail,
# 3-up, default sizes — the e2e suite leaves its own tweaks behind).
teardown
for app in "${SCENE_APPS[@]}"; do for _ in $(seq 1 30); do pgrep -x "$app" >/dev/null || break; sleep 0.1; done; done
defaults delete io.github.shidil.strip strip.settings.v1 2>/dev/null || true
# This runner's own Terminal window: minimized, so it neither joins the film nor shows in a shot.
osascript -e 'tell application "Terminal" to set miniaturized of front window to true' >/dev/null 2>&1

echo "Staging windows…"
write_pages
# Film order: Safari · Preview · Terminal · Chrome · Finder, so centering Chrome puts Terminal left
# and Finder right. Preview's toolbar gives it a ~700pt minimum width, too wide for a side slot on
# the VM's 1512pt display, so it waits off-screen.
stage 0 Safari launch_safari
stage 1 Preview launch_preview
stage 2 Terminal launch_terminal
stage 3 "Google Chrome" launch_chrome
stage 4 Finder launch_finder

rm -f "$STRIP_LOG"
open --env STRIP_VERBOSE=1 --env STRIP_LOG="$STRIP_LOG" "$APP"
line=$(wait_for_line "hotkeys:" 0 8) || fail "Strip didn't start (no hotkeys line in $STRIP_LOG)"
case "$line" in *"tap active"*) ;; *) fail "hotkey tap not active — Accessibility grant? ($line)" ;; esac
wait_for_total_count 5 0 10 >/dev/null || {
  cp=$(checkpoint); click_menu "Re-tile / Re-scan"
  wait_for_total_count 5 "$cp" 6 >/dev/null || fail "Strip isn't managing exactly the 5 scene windows"
}

# center_on <first word of app name> — rolls the film until that app's window holds focus.
center_on() {
  local cp block
  for _ in 1 2 3 4 5 6; do
    cp=$(checkpoint); click_menu "Re-tile / Re-scan"
    block=$(wait_for_new_apply "$cp" 3) || true
    [ "$(parse_focus_app "$block")" == "$1" ] && return 0
    send_hotkey slidePrev; sleep 0.6
  done
  fail "couldn't center $1"
}
# Shorter than Strip's full-height default (⌃⌥↓ = −5%), so the status pill and the film rail sit on
# the wallpaper instead of over the windows' toolbars and content. 0.85 is the tallest that clears
# the rail (checked on the 1512×949 and 3440×1440 displays).
SHOT_HEIGHT="${SHOT_HEIGHT:-0.85}"
steps=$(awk -v h="$SHOT_HEIGHT" 'BEGIN { printf "%d", (1 - h) / 0.05 + 0.5 }')
for _ in $(seq 1 "$steps"); do send_hotkey shorter; sleep 0.3; done
if [ "$steps" -gt 0 ]; then
  wait_for_line "height: $SHOT_HEIGHT" 0 4 >/dev/null || echo "  (height didn't reach $SHOT_HEIGHT)" >&2
fi
center_on Google
sleep 1.5 # let the springs and the focus ring settle

if wants strip; then shot strip; fi

if wants monocle; then
  cp=$(checkpoint); send_hotkey cols1
  wait_for_cols 1 "$cp" 3 >/dev/null || fail "monocle: never reached 1 column"
  sleep 1.5
  shot monocle
  cp=$(checkpoint); send_hotkey cols3; wait_for_cols 3 "$cp" 3 >/dev/null; sleep 1
fi

if wants pinned; then
  # Pin the right slot (Finder), focus back to the center, then roll the film: Finder holds its
  # slot (gold pin dot on its rail chip, "Hybrid" in the status pill) while the others move past.
  send_hotkey focusNext; sleep 0.4
  cp=$(checkpoint); send_hotkey togglePin
  block=$(wait_for_new_apply "$cp" 3) && grep -q pinned <<<"$block" || fail "pinned: no 'pinned' in the apply line"
  send_hotkey focusPrev; sleep 0.4
  cp=$(checkpoint); send_hotkey slideNext; wait_for_new_apply "$cp" 3 >/dev/null; sleep 1.5
  shot pinned
  # Unpin and restore the hero layout for the shots that follow.
  send_hotkey slidePrev; sleep 0.5
  send_hotkey focusNext; sleep 0.4
  cp=$(checkpoint); send_hotkey togglePin
  block=$(wait_for_new_apply "$cp" 3)
  grep -q pinned <<<"$block" && echo "  (pinned: unpin didn't take)" >&2
  send_hotkey focusPrev; sleep 0.4
  center_on Google; sleep 1
fi

if wants overview; then
  # Thumbnails of parked (off-screen) windows can't be captured, so warm the cache with each window
  # on screen once: Overview captures on open and keeps earlier captures for windows it can't reach.
  for _ in 1 2; do
    cp=$(checkpoint); send_hotkey toggleOverview; wait_for_line "overview: open" "$cp" 3 >/dev/null; sleep 1.2
    cp=$(checkpoint); send_hotkey toggleOverview; wait_for_line "overview: closed" "$cp" 3 >/dev/null
    send_hotkey slidePrev; sleep 0.6; send_hotkey slidePrev; sleep 0.8
  done
  center_on Google; sleep 1
  cp=$(checkpoint); send_hotkey toggleOverview
  wait_for_line "overview: open" "$cp" 3 >/dev/null || fail "Overview didn't open"
  sleep 1.8
  shot overview
  cp=$(checkpoint); send_hotkey toggleOverview; wait_for_line "overview: closed" "$cp" 3 >/dev/null
fi

if wants search || wants search-peek; then
  cp=$(checkpoint); send_hotkey toggleSearch
  wait_for_line "search: begin" "$cp" 3 >/dev/null || fail "search didn't open"
  wait_for_line "search: tabs Google" "$cp" 4 >/dev/null || echo "  (no Chrome tab scan line)" >&2
  type_text "spring"
  sleep 1.2
  # Peek follows ↑↓ only (typing never switches a real tab): ↓ previews Safari's tab, ↑ comes back
  # to Chrome's — restoring Safari's — so the big center card shows a peeked tab.
  send_key down; sleep 1.5
  if wants search-peek; then shot search-peek; fi
  send_key up; sleep 1.5
  if wants search; then shot search; fi
  for _ in 1 2 3; do
    cp=$(checkpoint); send_key escape
    wait_for_line "overview: closed" "$cp" 1 >/dev/null 2>&1 && break
  done
fi

if wants help; then
  send_hotkey toggleHelp; sleep 1
  shot help
  send_hotkey toggleHelp; sleep 0.5
fi

teardown
echo 0 >"$OUT/exitcode"
echo "=== done ==="

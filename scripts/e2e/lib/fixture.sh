#!/bin/bash
# Reproducible window set for the e2e suite: three built-in macOS apps, each producing exactly one
# window with a distinct, predictable app name — TextEdit, Activity Monitor, Preview. Setup quits
# any already-running instances first (so a prior session's stray windows can't skew a scenario's
# expected slotted/parked counts), then relaunches fresh. Teardown quits them again.
#
# NOT Calculator, despite being the obvious "no save prompt" choice: its window is permanently
# non-resizable (confirmed empirically — a System Events resize request is silently ignored), and
# StripController.isTileableSize requires a new window to be >= 20% of display width and 40% of
# display height before it's admitted to the ring. A stock Calculator/TextEdit/Preview window is
# comfortably below that on most displays, so every fixture window is explicitly resized after
# launch — this is not optional set-dressing, it's required for Strip to manage it at all.
#
# Also explicitly `activate`s each app: launching TextEdit via `make new document` alone left it
# with System Events `visible` false (never brought to the foreground), which excludes it from
# StripController.allWindows()'s `!app.isHidden` filter just as surely as being too small does.
#
# Does NOT wait for Strip to reconcile the new windows — that's a log-observable fact, and belongs
# next to the rest of the log-polling logic in lib/log_assert.sh. Callers (run.sh) checkpoint the log
# before calling setup_fixture, then wait_for_new_apply after.

FIXTURE_APPS=(TextEdit "Activity Monitor" Preview)
FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_IMAGE="$FIXTURE_DIR/fixtures/placeholder.png"

# Generated on demand instead of committed as a binary — a 1x1 transparent PNG is enough for Preview
# to open a window with a known, stable title ("placeholder.png"); it gets resized well past that
# 1x1 immediately after launch anyway (see _resize_window).
_ensure_fixture_image() {
  if [ -f "$FIXTURE_IMAGE" ]; then
    return
  fi
  mkdir -p "$(dirname "$FIXTURE_IMAGE")"
  base64 -D <<<"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" \
    >"$FIXTURE_IMAGE"
}

_quit_app() {
  osascript -e "tell application \"$1\" to if it is running then quit" >/dev/null 2>&1 || true
}

# quit_fixture_apps — quits the three fixture apps if running, ignoring errors either way.
quit_fixture_apps() {
  for app in "${FIXTURE_APPS[@]}"; do
    _quit_app "$app"
  done
  # Give the Dock/WindowServer a moment to actually tear the windows down before relaunching.
  for i in $(seq 1 20); do
    local any_running=0
    for app in "${FIXTURE_APPS[@]}"; do
      pgrep -x "$app" >/dev/null && any_running=1
    done
    [ "$any_running" -eq 0 ] && break
    sleep 0.1
  done
}

# _screen_size — prints "width height" of the main display (Finder's desktop window bounds, which
# is {0,0,width,height}).
_screen_size() {
  local bounds
  bounds=$(osascript -e 'tell application "Finder" to get bounds of window of desktop')
  echo "$bounds" | awk -F', ' '{print $3, $4}'
}

# _resize_window <process> — activates the app and grows its window to 60% of the screen in both
# dimensions (comfortably past the 20%/40% isTileableSize gate). Best-effort: if the app truly can't
# be resized (shouldn't happen for the three fixture apps — that's why Calculator was dropped), this
# silently leaves it at its default size and setup_fixture's caller (run.sh) will fail loudly via
# wait_for_total_count instead of here.
_resize_window() {
  local process="$1" w h
  read -r w h <<<"$(_screen_size)"
  w=$(( w * 6 / 10 ))
  h=$(( h * 6 / 10 ))
  osascript -e "tell application \"$process\" to activate" >/dev/null 2>&1
  osascript -e "tell application \"System Events\" to tell process \"$process\" to set size of window 1 to {$w, $h}" \
    >/dev/null 2>&1 || true
}

# setup_fixture — quits then relaunches TextEdit (blank doc), Activity Monitor, and Preview
# (placeholder image), resizing each so exactly 3 tileable, predictable windows exist. Does not wait
# for Strip to see them.
setup_fixture() {
  quit_fixture_apps
  _ensure_fixture_image

  osascript -e 'tell application "TextEdit" to make new document' >/dev/null
  open -a "Activity Monitor"
  open -a "Preview" "$FIXTURE_IMAGE"
  sleep 1

  for app in "${FIXTURE_APPS[@]}"; do
    _resize_window "$app"
  done
}

# teardown_fixture — quits the three fixture apps, ignoring errors if already gone.
teardown_fixture() {
  quit_fixture_apps
}

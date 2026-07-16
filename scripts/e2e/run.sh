#!/usr/bin/env bash
# Strip e2e smoke suite. NOT part of `make test` / the PostToolUse hook: this needs a granted
# Accessibility permission, a real display, and no other automation contending for the mouse/
# keyboard while it runs. It KILLS any running Strip instance and relaunches its own. See TESTING.md.
set -uo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$E2E_DIR/../.." && pwd)"
APP="$ROOT/.build/Strip.app"

export STRIP_LOG="${STRIP_LOG:-/tmp/strip-e2e.log}"
export STRIP_VERBOSE=1

# shellcheck source=lib/log_assert.sh
source "$E2E_DIR/lib/log_assert.sh"
# shellcheck source=lib/fixture.sh
source "$E2E_DIR/lib/fixture.sh"
# shellcheck source=lib/driver.sh
source "$E2E_DIR/lib/driver.sh"
# shellcheck source=scenarios.sh
source "$E2E_DIR/scenarios.sh"

SCENARIOS=(
  # constraint_learning runs FIRST deliberately: it converges every fixture window's learned size
  # bounds (SizeConstraint), so the later scenarios run in steady state — no more clamp-triggered
  # learning re-applies landing between a scenario's checkpoint and its own action's apply block
  # (wait_for_new_apply assumes the next new block is the driven action's).
  scenario_constraint_learning
  scenario_layout_switch
  scenario_slide
  scenario_focus_move
  scenario_move_focused_swap
  scenario_pin_unpin
  scenario_release_resume
  scenario_layout_submenu
  scenario_minimap_position
  scenario_focus_ring_toggle
  scenario_overview
  scenario_focus_ratio
  scenario_window_height
  scenario_gap_padding
)

cleanup() {
  teardown_fixture
}
trap cleanup EXIT

echo "=== Strip e2e suite ==="
echo "Log: $STRIP_LOG"

if [ ! -d "$APP" ]; then
  echo "✗ $APP not found — run 'make bundle' first (make e2e does this automatically)." >&2
  exit 1
fi

pkill -x Strip 2>/dev/null || true
sleep 0.3
# StripController.adjustFocusRatio/adjustHeight/adjustGap persist their knobs to UserDefaults
# (Model/Settings.swift, "strip.settings.v1" under io.github.shidil.strip) so they survive across launches —
# without this, scenario_focus_ratio/scenario_window_height/scenario_gap_padding from a previous run
# would leak into this one's starting state. The scenarios themselves are direction-tolerant of
# wherever they start (see scenarios.sh), but resetting keeps every run's starting point identical.
defaults delete io.github.shidil.strip strip.settings.v1 2>/dev/null || true
open --env STRIP_VERBOSE=1 --env STRIP_LOG="$STRIP_LOG" "$APP"

for i in $(seq 1 50); do
  pgrep -x Strip >/dev/null && break
  sleep 0.1
done
if ! pgrep -x Strip >/dev/null; then
  echo "✗ Strip did not start — check $STRIP_LOG" >&2
  exit 1
fi
# Wait for the hotkey tap to come up, not just the process — Strip's window-open observers can
# still be mid-setup right after process launch, and a fixture app opened in that gap can be missed
# until an explicit re-scan (handled below). Both HotkeyService log lines contain "hotkeys:" (tap
# active vs. failed to create event tap), so check which one matched instead of ignoring the result —
# a real tap failure (Accessibility not granted) should fail fast here, not surface later as a
# confusing hotkey-scenario timeout.
hotkey_line=$(wait_for_line "hotkeys:" 0 5) || true
if [[ "$hotkey_line" == *"failed to create event tap"* ]]; then
  echo "✗ Strip's hotkey tap failed to start — is Accessibility granted? ($hotkey_line)" >&2
  exit 1
fi

echo "Setting up fixture (Console, Activity Monitor, Preview)…"
setup_fixture
sleep 1
# Force a re-enumerate in case Strip's window-open observer missed a fixture app's launch (a race
# right after Strip's own startup, before its observers are fully wired) — cheap and idempotent.
click_menu "Re-tile / Re-scan"
fixture_block=$(wait_for_total_count 3 0 8)
if [ $? -ne 0 ]; then
  echo "✗ Strip is managing more than the 3 fixture windows (Console, Activity Monitor, Preview)." >&2
  echo "  This suite needs a clean desktop — quit any other windowed apps (Slack, browsers," >&2
  echo "  terminals, etc.) and re-run 'make e2e'. Last known state:" >&2
  tail -n 10 "$STRIP_LOG" | sed 's/^/    /' >&2
  exit 1
fi

pass=0
fail=0
failed_names=()
for name in "${SCENARIOS[@]}"; do
  echo "--- $name ---"
  sleep 0.3 # let the previous scenario's UI state (menus, key events) fully settle first
  if "$name"; then
    echo "  ✓ PASS"
    pass=$((pass + 1))
  else
    echo "  ✗ FAIL"
    fail=$((fail + 1))
    failed_names+=("$name")
  fi
done

echo
echo "=== Summary: $pass passed, $fail failed ==="
if [ "$fail" -gt 0 ]; then
  echo "Failed: ${failed_names[*]}"
  echo "Full log: $STRIP_LOG"
  exit 1
fi
exit 0

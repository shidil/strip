#!/bin/bash
# Parses /tmp/strip.log (or $STRIP_LOG) as the e2e suite's assertion oracle. Pure text-processing —
# no AppKit/AX/osascript here — so this file alone can be sanity-checked against a saved log excerpt
# without a live app. See TESTING.md.
#
# Log shape this depends on (Sources/StripKit/StripController.swift:751 `logState`):
#   apply: <cols>-up · <focus|equal> on <screen> — N slotted, M parked[ — pinned ...]     (always)
#      <●|·> <appName> slot=<L|C|R|PARKED> frame=(x,y wxh) [◀focus]                       (STRIP_VERBOSE only)
# `●`/`◀focus` both mark the *focused* slot (StripLayout.placements(in:).active == (inSlot == focusSlot)),
# not the centered one — there is no separate "this is centered" marker.

STRIP_E2E_LOG="${STRIP_LOG:-/tmp/strip.log}"

# Current line count of the log file. Callers snapshot this before driving an action, then pass it
# to wait_for_new_apply so a stale block from an earlier action can't be misread as this action's
# result.
checkpoint() {
  if [ -f "$STRIP_E2E_LOG" ]; then
    wc -l < "$STRIP_E2E_LOG" | tr -d ' '
  else
    echo 0
  fi
}

# _latest_apply_block_since <since_line> — if a new `apply:` line exists after line <since_line>,
# prints it plus any immediately-following verbose per-window lines and returns 0; else returns 1.
# Private: shared by wait_for_new_apply and wait_for_slotted_count below.
_latest_apply_block_since() {
  local since="$1" total new_lines block
  total=$(wc -l < "$STRIP_E2E_LOG" 2>/dev/null | tr -d ' ')
  total=${total:-0}
  [ "$total" -gt "$since" ] || return 1
  new_lines=$(tail -n "+$((since + 1))" "$STRIP_E2E_LOG")
  grep -q "apply:" <<<"$new_lines" || return 1
  block=$(awk '
    /apply:/ { start = NR }
    { lines[NR] = $0 }
    END {
      if (!start) exit 1
      print lines[start]
      for (i = start + 1; i <= NR; i++) {
        if (lines[i] !~ /slot=.*frame=\(/) break
        print lines[i]
      }
    }
  ' <<<"$new_lines")
  [ -n "$block" ] || return 1
  printf '%s\n' "$block"
}

# wait_for_new_apply <since_line> [timeout_seconds]
# Polls the log for a new `apply:` block appearing after line <since_line>, and prints the LAST
# such block (summary line + any immediately-following verbose per-window lines) to stdout. Returns
# 1 (with a message on stderr) on timeout. Use this after a single driven action.
wait_for_new_apply() {
  local since="$1" timeout="${2:-3}" iterations block
  iterations=$(( timeout * 10 ))
  for ((i = 0; i < iterations; i++)); do
    if block=$(_latest_apply_block_since "$since"); then
      printf '%s\n' "$block"
      return 0
    fi
    sleep 0.1
  done
  echo "TIMEOUT: no new 'apply:' block after line $since within ${timeout}s (log=$STRIP_E2E_LOG)" >&2
  return 1
}

# wait_for_slotted_count <target> <since_line> [timeout_seconds]
# Polls until the latest apply block since <since_line> reports exactly <target> slotted windows —
# needed for fixture setup, where 3 apps can be discovered by Strip's reconcile across several
# transitional apply()s (1 slotted, then 2, then 3), not necessarily in one shot.
wait_for_slotted_count() {
  local target="$1" since="$2" timeout="${3:-8}" iterations block
  iterations=$(( timeout * 10 ))
  for ((i = 0; i < iterations; i++)); do
    if block=$(_latest_apply_block_since "$since") && [ "$(parse_count "$block" slotted)" == "$target" ]; then
      printf '%s\n' "$block"
      return 0
    fi
    sleep 0.1
  done
  echo "TIMEOUT: never saw $target slotted after line $since within ${timeout}s (log=$STRIP_E2E_LOG)" >&2
  return 1
}

# wait_for_total_count <target> <since_line> [timeout_seconds]
# Polls until slotted+parked == <target> — i.e. Strip is managing *exactly* that many windows, no
# more. Used as the fixture suite's "clean desktop" gate: if other real app windows are open, Strip
# will manage those too and slotted/parked counts stop being a deterministic oracle. Fails loudly
# (rather than silently running scenarios against an unknown extra window set) if the desktop isn't
# clean within the timeout.
wait_for_total_count() {
  local target="$1" since="$2" timeout="${3:-8}" iterations block
  iterations=$(( timeout * 10 ))
  for ((i = 0; i < iterations; i++)); do
    if block=$(_latest_apply_block_since "$since"); then
      local total=$(( $(parse_count "$block" slotted) + $(parse_count "$block" parked) ))
      if [ "$total" == "$target" ]; then
        printf '%s\n' "$block"
        return 0
      fi
    fi
    sleep 0.1
  done
  echo "TIMEOUT: Strip never settled at exactly $target managed window(s) after line $since within ${timeout}s (log=$STRIP_E2E_LOG)" >&2
  return 1
}

# wait_for_line <pattern> <since_line> [timeout_seconds] — for the log lines that aren't part of an
# apply block (release-all suspend/resume, "rail edge: x", "focus ring: on|off"). Prints the first
# new matching line and returns 0, or times out.
wait_for_line() {
  local pattern="$1" since="$2" timeout="${3:-3}" iterations
  iterations=$(( timeout * 10 ))
  for ((i = 0; i < iterations; i++)); do
    local total
    total=$(wc -l < "$STRIP_E2E_LOG" 2>/dev/null | tr -d ' ')
    total=${total:-0}
    if [ "$total" -gt "$since" ]; then
      local match
      match=$(tail -n "+$((since + 1))" "$STRIP_E2E_LOG" | grep -m1 -E "$pattern")
      if [ -n "$match" ]; then
        printf '%s\n' "$match"
        return 0
      fi
    fi
    sleep 0.1
  done
  echo "TIMEOUT: no line matching /$pattern/ after line $since within ${timeout}s (log=$STRIP_E2E_LOG)" >&2
  return 1
}

# parse_cols <block> — prints the column count (1 for "monocle", else the N in "N-up").
parse_cols() {
  if grep -q "apply: monocle" <<<"$1"; then
    echo 1
    return
  fi
  grep -oE "apply: [0-9]+-up" <<<"$1" | grep -oE "[0-9]+"
}

# parse_count <block> <slotted|parked> — prints the matching count from the summary line.
parse_count() {
  grep -oE "[0-9]+ $2" <<<"$1" | head -1 | grep -oE "^[0-9]+"
}

# Every log line is timestamp-prefixed (Log.line), so a verbose per-window line splits (by
# whitespace) as: $1 timestamp, $2 bullet (●|·), $3 appName, $4 slot=..., $5-6 frame=(...), $7 mark.

# parse_focus_app <block> — prints the appName on the line marked ◀focus (verbose lines only).
parse_focus_app() {
  grep "◀focus" <<<"$1" | awk '{print $3}' | head -1
}

# parse_slot_app <block> <L|C|R|PARKED> — prints the appName occupying the given slot (verbose only).
parse_slot_app() {
  grep -E "slot=$2([[:space:]]|$)" <<<"$1" | awk '{print $3}' | head -1
}

# assert_eq <actual> <expected> <description> — prints a failure line to stderr and returns 1 on
# mismatch; silent success otherwise.
assert_eq() {
  if [ "$1" == "$2" ]; then
    return 0
  fi
  echo "    ✗ $3: expected '$2', got '$1'" >&2
  return 1
}

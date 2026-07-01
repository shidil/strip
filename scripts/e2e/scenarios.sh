#!/bin/bash
# One function per v1 scenario. Each assumes the 3-window fixture (exactly 3 slotted windows in
# 3-up, 0 parked) and runs against whatever apps currently occupy L/C/R — it reads that from the
# log rather than assuming which fixture app lands where (ring/slot assignment order at startup
# isn't something the suite controls). Each function returns 0 on pass, 1 on fail, and on fail has
# already printed the mismatch (via assert_eq) plus should print the log block it was checking.
#
# Semantics encoded here were verified live against a running Strip instance while writing this
# suite (not assumed from reading the source alone) — see TESTING.md for the transcript.

_fail_dump() { # $1=block — print the block for a failing scenario
  echo "    log block:" >&2
  sed 's/^/      /' <<<"$1" >&2
}

scenario_layout_switch() {
  local ok=0 cp block
  cp=$(checkpoint); send_hotkey cols1; block=$(wait_for_new_apply "$cp" 3) || { _fail_dump ""; return 1; }
  assert_eq "$(parse_cols "$block")" "1" "cols1 -> cols" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_count "$block" slotted)" "1" "cols1 -> slotted" || { ok=1; _fail_dump "$block"; }

  cp=$(checkpoint); send_hotkey cols2; block=$(wait_for_new_apply "$cp" 3) || { _fail_dump ""; return 1; }
  assert_eq "$(parse_cols "$block")" "2" "cols2 -> cols" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_count "$block" slotted)" "2" "cols2 -> slotted" || { ok=1; _fail_dump "$block"; }

  cp=$(checkpoint); send_hotkey cols3; block=$(wait_for_new_apply "$cp" 3) || { _fail_dump ""; return 1; }
  assert_eq "$(parse_cols "$block")" "3" "cols3 -> cols" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_count "$block" slotted)" "3" "cols3 -> slotted" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_count "$block" parked)" "0" "cols3 -> parked" || { ok=1; _fail_dump "$block"; }
  return "$ok"
}

scenario_slide() {
  local ok=0 cp block before_l before_c before_r
  cp=$(checkpoint); send_hotkey cols3; block=$(wait_for_new_apply "$cp" 3) || return 1
  before_l=$(parse_slot_app "$block" L); before_c=$(parse_slot_app "$block" C); before_r=$(parse_slot_app "$block" R)

  cp=$(checkpoint); send_hotkey slideNext; block=$(wait_for_new_apply "$cp" 3) || return 1
  # exactly 3 fixture windows in 3-up -> slide just rotates L/C/R, no parking.
  assert_eq "$(parse_count "$block" slotted)" "3" "slideNext -> still 3 slotted" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_count "$block" parked)" "0" "slideNext -> still 0 parked" || { ok=1; _fail_dump "$block"; }
  if [ "$(parse_slot_app "$block" C)" == "$before_c" ]; then
    echo "    ✗ slideNext: center occupant did not change ($before_c)" >&2
    ok=1; _fail_dump "$block"
  fi

  cp=$(checkpoint); send_hotkey slidePrev; block=$(wait_for_new_apply "$cp" 3) || return 1
  assert_eq "$(parse_slot_app "$block" L)" "$before_l" "slidePrev round-trip -> L" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_slot_app "$block" C)" "$before_c" "slidePrev round-trip -> C" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_slot_app "$block" R)" "$before_r" "slidePrev round-trip -> R" || { ok=1; _fail_dump "$block"; }
  return "$ok"
}

scenario_focus_move() {
  local ok=0 cp block center_app before_focus
  cp=$(checkpoint); send_hotkey cols3; block=$(wait_for_new_apply "$cp" 3) || return 1
  # Reset focus to L first (2x focusPrev clamps there, no wrap) so focusNext below is guaranteed to
  # have a next slot (C) rather than risking a same-state no-op if focus happened to start at R.
  send_hotkey focusPrev; sleep 0.2
  cp=$(checkpoint); send_hotkey focusPrev; block=$(wait_for_new_apply "$cp" 3) || return 1
  center_app=$(parse_slot_app "$block" C)
  before_focus=$(parse_focus_app "$block")

  cp=$(checkpoint); send_hotkey focusNext; block=$(wait_for_new_apply "$cp" 3) || return 1
  assert_eq "$(parse_slot_app "$block" C)" "$center_app" "focusNext -> center unchanged" || { ok=1; _fail_dump "$block"; }
  if [ "$(parse_focus_app "$block")" == "$before_focus" ]; then
    echo "    ✗ focusNext: focused app did not change ($before_focus)" >&2
    ok=1; _fail_dump "$block"
  fi

  cp=$(checkpoint); send_hotkey focusPrev; block=$(wait_for_new_apply "$cp" 3) || return 1
  assert_eq "$(parse_focus_app "$block")" "$before_focus" "focusPrev round-trip -> focus" || { ok=1; _fail_dump "$block"; }
  return "$ok"
}

# Carries the FOCUSED window (⌃⌥⇧H/L), not necessarily the centered one — the behavior fixed by
# StripState.moveFocused (HANDOFF.md "Swap focused <-> neighbor"). Resets focus to L first (2x
# focusPrev clamps there, no wrap) for a deterministic, non-edge starting slot.
scenario_move_focused_swap() {
  local ok=0 cp block l_app c_app focus_app
  cp=$(checkpoint); send_hotkey cols3; block=$(wait_for_new_apply "$cp" 3) || return 1
  send_hotkey focusPrev; sleep 0.2
  cp=$(checkpoint); send_hotkey focusPrev; block=$(wait_for_new_apply "$cp" 3) || return 1
  assert_eq "$(parse_slot_app "$block" L)" "$(parse_focus_app "$block")" "reset -> focus on L" || { ok=1; _fail_dump "$block"; return 1; }
  l_app=$(parse_slot_app "$block" L); c_app=$(parse_slot_app "$block" C)

  cp=$(checkpoint); send_hotkey moveNext; block=$(wait_for_new_apply "$cp" 3) || return 1
  assert_eq "$(parse_slot_app "$block" C)" "$l_app" "moveNext -> L's window carried to C" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_focus_app "$block")" "$l_app" "moveNext -> focus rides the moved window" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_slot_app "$block" L)" "$c_app" "moveNext -> displaced C's window to L" || { ok=1; _fail_dump "$block"; }

  cp=$(checkpoint); send_hotkey movePrev; block=$(wait_for_new_apply "$cp" 3) || return 1
  assert_eq "$(parse_slot_app "$block" L)" "$l_app" "movePrev round-trip -> L" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_slot_app "$block" C)" "$c_app" "movePrev round-trip -> C" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_focus_app "$block")" "$l_app" "movePrev round-trip -> focus still on carried window" || { ok=1; _fail_dump "$block"; }
  return "$ok"
}

scenario_pin_unpin() {
  local ok=0 cp block pinned_app other_before
  cp=$(checkpoint); send_hotkey cols3; block=$(wait_for_new_apply "$cp" 3) || return 1
  pinned_app=$(parse_focus_app "$block")

  cp=$(checkpoint); send_hotkey togglePin; block=$(wait_for_new_apply "$cp" 3) || return 1
  if ! grep -q "pinned" <<<"$block"; then
    echo "    ✗ togglePin: no 'pinned' marker in summary line" >&2
    ok=1; _fail_dump "$block"
  fi

  cp=$(checkpoint); send_hotkey slideNext; block=$(wait_for_new_apply "$cp" 3) || return 1
  assert_eq "$(parse_focus_app "$block")" "$pinned_app" "slide with pin held -> pinned slot unchanged" || { ok=1; _fail_dump "$block"; }

  send_hotkey slidePrev; sleep 0.2
  cp=$(checkpoint); send_hotkey togglePin; block=$(wait_for_new_apply "$cp" 3) || return 1
  if grep -q "pinned" <<<"$block"; then
    echo "    ✗ togglePin (unpin): 'pinned' marker still present" >&2
    ok=1; _fail_dump "$block"
  fi
  return "$ok"
}

scenario_release_resume() {
  local ok=0 cp line
  cp=$(checkpoint); send_hotkey releaseAll
  line=$(wait_for_line "SUSPENDED" "$cp" 3) || { ok=1; echo "    ✗ releaseAll: no SUSPENDED line" >&2; }

  cp=$(checkpoint); send_hotkey releaseAll
  line=$(wait_for_line "RESUMED" "$cp" 3) || { ok=1; echo "    ✗ releaseAll (again): no RESUMED line" >&2; }
  return "$ok"
}

scenario_minimap_position() {
  local ok=0 cp line edge edge_lower
  for edge in Top Left Right Bottom; do
    edge_lower=$(tr '[:upper:]' '[:lower:]' <<<"$edge")
    cp=$(checkpoint)
    click_submenu "Minimap position" "$edge"
    line=$(wait_for_line "rail edge: $edge_lower" "$cp" 3) || { ok=1; echo "    ✗ minimap position: no 'rail edge: $edge_lower' line" >&2; }
  done
  return "$ok"
}

scenario_focus_ring_toggle() {
  local ok=0 cp line
  cp=$(checkpoint); click_menu "Show focus ring"
  line=$(wait_for_line "focus ring:" "$cp" 3) || { ok=1; echo "    ✗ focus ring toggle: no 'focus ring:' line" >&2; }

  cp=$(checkpoint); click_menu "Show focus ring"
  line=$(wait_for_line "focus ring:" "$cp" 3) || { ok=1; echo "    ✗ focus ring toggle (again): no 'focus ring:' line" >&2; }
  return "$ok"
}

scenario_overview() {
  local ok=0 cp line
  cp=$(checkpoint); click_menu "Overview"
  line=$(wait_for_line "overview: open" "$cp" 3) || { ok=1; echo "    ✗ overview: no 'overview: open' line" >&2; }

  cp=$(checkpoint); click_menu "Overview"
  line=$(wait_for_line "overview: closed" "$cp" 3) || { ok=1; echo "    ✗ overview (close): no 'overview: closed' line" >&2; }
  return "$ok"
}

scenario_layout_submenu() {
  local ok=0 cp block
  cp=$(checkpoint); click_submenu "Layout" "Monocle (1)"; block=$(wait_for_new_apply "$cp" 3) || return 1
  assert_eq "$(parse_cols "$block")" "1" "menu Monocle (1) -> cols" || { ok=1; _fail_dump "$block"; }

  cp=$(checkpoint); click_submenu "Layout" "2-up (2)"; block=$(wait_for_new_apply "$cp" 3) || return 1
  assert_eq "$(parse_cols "$block")" "2" "menu 2-up (2) -> cols" || { ok=1; _fail_dump "$block"; }

  cp=$(checkpoint); click_submenu "Layout" "3-up (3)"; block=$(wait_for_new_apply "$cp" 3) || return 1
  assert_eq "$(parse_cols "$block")" "3" "menu 3-up (3) -> cols" || { ok=1; _fail_dump "$block"; }
  return "$ok"
}

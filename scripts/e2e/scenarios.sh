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

_abs_diff() { local d=$(( $1 - $2 )); echo "${d#-}"; }

# _scaled100 <numstr> — prints <numstr> * 100 as a plain integer, for comparing the "%.2f"-formatted
# knob values (e.g. "0.55", "0.34") with bash's integer-only arithmetic (no `bc`/`awk` dependency,
# consistent with this suite's stock-/bin/bash-3.2-compatible style — see driver.sh's header comment).
# "0.55" -> strip the dot -> "055" -> forced base-10 (bash would otherwise read a leading zero as
# octal) -> 55. Plain integers (e.g. gap's "4") are just multiplied by 100 directly.
_scaled100() {
  local v="$1"
  if [[ "$v" == *.* ]]; then
    echo "$((10#${v/./}))"
  else
    echo "$((v * 100))"
  fi
}

# _frames_match <"x y w h"> <"x y w h"> [tolerance] — loose equality on two space-separated frames.
_frames_match() {
  local ax ay aw ah bx by bw bh tol="${3:-2}"
  read -r ax ay aw ah <<<"$1"
  read -r bx by bw bh <<<"$2"
  [ -n "$ax" ] && [ -n "$bx" ] \
    && [ "$(_abs_diff "$ax" "$bx")" -le "$tol" ] \
    && [ "$(_abs_diff "$ay" "$by")" -le "$tol" ] \
    && [ "$(_abs_diff "$aw" "$bw")" -le "$tol" ] \
    && [ "$(_abs_diff "$ah" "$bh")" -le "$tol" ]
}

# _assert_real_frame <appName> <expected: "x y w h"> <since_line> [timeout_seconds] — polls the REAL,
# live AX frame of appName's window (real_window_frame, driver.sh) until it matches <expected> within
# a small pixel tolerance. Strip's log (parse_frame_for_literal_app) only proves what Strip *decided*
# the frame should be, the instant it decided it — WindowAnimator's spring (Animation/Spring.swift)
# can take a moment to actually settle the real window there, so this polls rather than comparing
# once (which would race the animation, not catch a real bug).
#
# If the real frame never matches <expected>, the app clamped our resize (its own min/fixed content
# size). Strip must have detected that (a "frame-clamped:" line, StripController.reconcileClampedFrame)
# — and when the clamp taught it a size constraint (a "constraint-learned:" line, SizeConstraint), it
# re-applies with slots sized around the learned bounds, so the contract escalates from "honestly
# record the drift" to CONVERGENCE: the latest apply's commanded frame for this app must come to
# match the live real frame. Only a clamp that taught nothing (sub-threshold drift) may settle for
# the honest record. "Never detected", "recorded the wrong value", and "learned but never converged"
# are different bugs and get different failure messages.
_assert_real_frame() {
  local app="$1" expected="$2" since="$3" timeout="${4:-3}" iterations
  iterations=$(( timeout * 10 ))
  local live=""
  for ((i = 0; i < iterations; i++)); do
    live=$(real_window_frame "$app")
    [ -n "$live" ] && _frames_match "$live" "$expected" && return 0
    sleep 0.1
  done
  local clamp_actual
  if clamp_actual=$(parse_clamp_actual_for_app "$since" "$app" 2); then
    if log_has_since "$since" "constraint-learned: $app " 2; then
      # Learning fired → a re-apply is coming (possibly several, if one window's raised floor
      # re-flows a neighbor into its own floor). Poll the LATEST apply block each round rather than
      # waiting for one specific block, so cascades converge too.
      local block2 expected2=""
      for ((i = 0; i < 50; i++)); do
        if block2=$(_latest_apply_block_since "$since") \
           && expected2=$(parse_frame_for_literal_app "$block2" "$app"); then
          live=$(real_window_frame "$app")
          [ -n "$live" ] && _frames_match "$live" "$expected2" && return 0
        fi
        sleep 0.1
      done
      echo "    ✗ $app: learned a size constraint but never converged — latest commanded (${expected2:-?}) vs live real frame ($live)" >&2
      return 1
    fi
    if _frames_match "$clamp_actual" "$live"; then
      return 0
    fi
    echo "    ✗ $app: Strip logged a frame-clamped correction ($clamp_actual) that doesn't match the live real frame ($live)" >&2
    return 1
  fi
  echo "    ✗ $app: real window frame ($live) never matched Strip's logged frame ($expected), and Strip never detected the mismatch (no frame-clamped line) within ${timeout}s" >&2
  return 1
}

scenario_layout_switch() {
  # wait_for_cols (not wait_for_new_apply): a constraint-learning re-apply of the previous layout
  # can land right after the checkpoint and would otherwise be mistaken for this hotkey's apply.
  local ok=0 cp block
  cp=$(checkpoint); send_hotkey cols1; block=$(wait_for_cols 1 "$cp" 3) || { _fail_dump ""; return 1; }
  assert_eq "$(parse_count "$block" slotted)" "1" "cols1 -> slotted" || { ok=1; _fail_dump "$block"; }

  cp=$(checkpoint); send_hotkey cols2; block=$(wait_for_cols 2 "$cp" 3) || { _fail_dump ""; return 1; }
  assert_eq "$(parse_count "$block" slotted)" "2" "cols2 -> slotted" || { ok=1; _fail_dump "$block"; }

  cp=$(checkpoint); send_hotkey cols3; block=$(wait_for_cols 3 "$cp" 3) || { _fail_dump ""; return 1; }
  assert_eq "$(parse_count "$block" slotted)" "3" "cols3 -> slotted" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_count "$block" parked)" "0" "cols3 -> parked" || { ok=1; _fail_dump "$block"; }

  # Cross-check against the real world, not just Strip's own account of it: the assertions above only
  # prove Strip *decided* on these frames, which can't catch a WindowAnimator/AX-write bug where the
  # real window never actually got there (see TESTING.md's "trusting Strip's own log" discussion).
  local app expected
  for app in "${FIXTURE_APPS[@]}"; do
    expected=$(parse_frame_for_literal_app "$block" "$app") || { ok=1; echo "    ✗ $app: no frame in log block" >&2; continue; }
    _assert_real_frame "$app" "$expected" "$cp" 3 || ok=1
  done
  return "$ok"
}

# The constraint-learning loop end-to-end (SizeConstraint → reconcileClampedFrame → re-apply): in
# 3-up on the small VM display the peek slots are far narrower than Console's (~600px) / Activity
# Monitor's (~740px) real contentMinSize, so Strip must detect each clamp, learn the floor,
# re-apply, and converge (real frames match the commanded ones). Then the monotonic no-churn
# guarantee: re-entering the same layout must clamp nothing and learn nothing new.
scenario_constraint_learning() {
  local ok=0 cp block app expected
  cp=$(checkpoint); send_hotkey cols3; block=$(wait_for_cols 3 "$cp" 3) || { _fail_dump ""; return 1; }
  for app in "${FIXTURE_APPS[@]}"; do
    expected=$(parse_frame_for_literal_app "$block" "$app") || { ok=1; echo "    ✗ $app: no frame in log block" >&2; continue; }
    _assert_real_frame "$app" "$expected" "$cp" 3 || ok=1
  done

  # Snapshot how much has been learned, bounce the layout, and come back: same slots, now solved
  # with the learned floors → commanded ≥ every floor → no clamp, no new learning.
  local before after
  before=$(grep -cF "constraint-learned:" "$STRIP_E2E_LOG" || true)
  cp=$(checkpoint); send_hotkey cols1; wait_for_cols 1 "$cp" 3 >/dev/null || { _fail_dump ""; return 1; }
  cp=$(checkpoint); send_hotkey cols3; block=$(wait_for_cols 3 "$cp" 3) || { _fail_dump ""; return 1; }
  for app in "${FIXTURE_APPS[@]}"; do
    expected=$(parse_frame_for_literal_app "$block" "$app") || { ok=1; continue; }
    _assert_real_frame "$app" "$expected" "$cp" 3 || { ok=1; echo "    ✗ $app: did not stay converged on repeat cols3" >&2; }
  done
  # Give a would-be stray settle read-back a beat to log before counting.
  sleep 1
  after=$(grep -cF "constraint-learned:" "$STRIP_E2E_LOG" || true)
  assert_eq "$after" "$before" "repeat cols3 -> no new constraint-learned lines (monotone, no churn)" || ok=1
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
# StripState.moveFocused swaps the focused window with its neighboring slot. Resets focus to L first (2x
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
  # wait_for_cols (not wait_for_new_apply): a constraint-learning re-apply of the previous layout
  # can land right after the checkpoint and would otherwise be mistaken for this click's apply.
  local ok=0 cp block
  cp=$(checkpoint); click_submenu "Layout" "Monocle (1)"; block=$(wait_for_cols 1 "$cp" 3) || { ok=1; echo "    ✗ menu Monocle (1): never reached 1-col" >&2; }
  cp=$(checkpoint); click_submenu "Layout" "2-up (2)"; block=$(wait_for_cols 2 "$cp" 3) || { ok=1; echo "    ✗ menu 2-up (2): never reached 2-col" >&2; }
  cp=$(checkpoint); click_submenu "Layout" "3-up (3)"; block=$(wait_for_cols 3 "$cp" 3) || { ok=1; echo "    ✗ menu 3-up (3): never reached 3-col" >&2; }
  return "$ok"
}

# Widen/narrow the dominant window (⌃⌥= / ⌃⌥-). `StripController.adjustFocusRatio` persists
# `focusRatio` across launches (Model/Settings.swift), so a prior run (or interactive use on the same
# machine) can leave it sitting anywhere in its clamped range (LayoutConfig.focusRatioRange, 0.34–
# 0.85) — this checks *direction* (narrow never increases it, widen never decreases it) rather than an
# exact value or round-trip, and treats a clamped no-op landing exactly on a documented bound as a
# pass rather than a flake.
scenario_focus_ratio() {
  local ok=0 cp block line v0 v1 v2
  cp=$(checkpoint); send_hotkey cols3; block=$(wait_for_new_apply "$cp" 3) || return 1

  cp=$(checkpoint); send_hotkey focusWider
  line=$(wait_for_line "focus ratio:" "$cp" 3) || { ok=1; echo "    ✗ focusWider: no 'focus ratio:' line" >&2; return 1; }
  v0=$(parse_num_after "$line" "focus ratio")

  cp=$(checkpoint); send_hotkey focusNarrower
  line=$(wait_for_line "focus ratio:" "$cp" 3) || { ok=1; echo "    ✗ focusNarrower: no 'focus ratio:' line" >&2; return 1; }
  v1=$(parse_num_after "$line" "focus ratio")
  if [ "$(_scaled100 "$v1")" -gt "$(_scaled100 "$v0")" ]; then
    echo "    ✗ focusNarrower: ratio $v1 increased from $v0" >&2; ok=1
  elif [ "$v1" == "$v0" ] && [ "$v0" != "0.34" ]; then
    echo "    ✗ focusNarrower: ratio stuck at $v0 (not at the documented lower bound 0.34)" >&2; ok=1
  fi

  cp=$(checkpoint); send_hotkey focusWider
  line=$(wait_for_line "focus ratio:" "$cp" 3) || { ok=1; echo "    ✗ focusWider (2nd): no 'focus ratio:' line" >&2; return 1; }
  v2=$(parse_num_after "$line" "focus ratio")
  if [ "$(_scaled100 "$v2")" -lt "$(_scaled100 "$v1")" ]; then
    echo "    ✗ focusWider: ratio $v2 decreased from $v1" >&2; ok=1
  elif [ "$v2" == "$v1" ] && [ "$v1" != "0.85" ]; then
    echo "    ✗ focusWider: ratio stuck at $v1 (not at the documented upper bound 0.85)" >&2; ok=1
  fi
  return "$ok"
}

# Grow/shrink every window's height (⌃⌥↑ / ⌃⌥↓). Same persisted-knob caveat and direction-tolerant
# checking as scenario_focus_ratio (LayoutConfig.heightRange, 0.4–1.0).
scenario_window_height() {
  local ok=0 cp line v0 v1 v2
  cp=$(checkpoint); send_hotkey taller
  line=$(wait_for_line "height:" "$cp" 3) || { ok=1; echo "    ✗ taller: no 'height:' line" >&2; return 1; }
  v0=$(parse_num_after "$line" "height")

  cp=$(checkpoint); send_hotkey shorter
  line=$(wait_for_line "height:" "$cp" 3) || { ok=1; echo "    ✗ shorter: no 'height:' line" >&2; return 1; }
  v1=$(parse_num_after "$line" "height")
  if [ "$(_scaled100 "$v1")" -gt "$(_scaled100 "$v0")" ]; then
    echo "    ✗ shorter: height $v1 increased from $v0" >&2; ok=1
  elif [ "$v1" == "$v0" ] && [ "$v0" != "0.40" ]; then
    echo "    ✗ shorter: height stuck at $v0 (not at the documented lower bound 0.4)" >&2; ok=1
  fi

  cp=$(checkpoint); send_hotkey taller
  line=$(wait_for_line "height:" "$cp" 3) || { ok=1; echo "    ✗ taller (2nd): no 'height:' line" >&2; return 1; }
  v2=$(parse_num_after "$line" "height")
  if [ "$(_scaled100 "$v2")" -lt "$(_scaled100 "$v1")" ]; then
    echo "    ✗ taller: height $v2 decreased from $v1" >&2; ok=1
  elif [ "$v2" == "$v1" ] && [ "$v1" != "1.00" ]; then
    echo "    ✗ taller: height stuck at $v1 (not at the documented upper bound 1.0)" >&2; ok=1
  fi
  return "$ok"
}

# Tighten/loosen the inter-window gap and outer padding together (⌃⌥[ / ⌃⌥]). Only floored at 0 (no
# upper bound — Model/LayoutConfig.swift / StripController.adjustGap), so loosening first (away from
# that floor) then tightening back by the same fixed step (4pt) round-trips exactly regardless of
# whatever value a prior run's persisted state left it at.
scenario_gap_padding() {
  local ok=0 cp line gap0 pad0 gap1 pad1
  cp=$(checkpoint); send_hotkey gapLooser
  line=$(wait_for_line "gap:" "$cp" 3) || { ok=1; echo "    ✗ gapLooser: no 'gap:' line" >&2; return 1; }
  gap0=$(parse_num_after "$line" "gap"); pad0=$(parse_num_after "$line" "pad")

  cp=$(checkpoint); send_hotkey gapTighter
  line=$(wait_for_line "gap:" "$cp" 3) || { ok=1; echo "    ✗ gapTighter: no 'gap:' line" >&2; return 1; }
  gap1=$(parse_num_after "$line" "gap"); pad1=$(parse_num_after "$line" "pad")

  assert_eq "$gap1" "$((gap0 - 4))" "gapTighter -> gap round-trips" || ok=1
  assert_eq "$pad1" "$((pad0 - 4))" "gapTighter -> pad round-trips" || ok=1
  return "$ok"
}

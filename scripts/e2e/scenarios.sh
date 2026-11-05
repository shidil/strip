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
  # Cascade from ANOTHER window: its learned floor re-flowed the row, so a later apply re-targeted
  # this one (seen in the VM: Preview re-laid from (688 2064) to (756 2013) after a neighbor's
  # constraint-learned). The contract is convergence on the LATEST commanded frame.
  local latest expected3
  if latest=$(_latest_apply_block_since "$since") \
     && expected3=$(parse_frame_for_literal_app "$latest" "$app") \
     && [ "$expected3" != "$expected" ]; then
    for ((i = 0; i < 30; i++)); do
      live=$(real_window_frame "$app")
      [ -n "$live" ] && _frames_match "$live" "$expected3" && return 0
      sleep 0.1
    done
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

# _parked_left_app <block> — prints the full appName of the window parked off the LEFT edge (verbose
# placement lines: "<ts> <●|·> <name…> slot=PARKED frame=(x,y wxh)", x negative), or nothing.
_parked_left_app() {
  grep "slot=PARKED" <<<"$1" | grep -E 'frame=\(-[0-9]+,' | head -1 \
    | sed -E 's/^[^ ]+ +[●·] +//; s/ +slot=.*//'
}

# _sample_mid_x <appName> <seconds> — polls the REAL window frame and prints each sample's midX,
# one per line (ground truth, independent of Strip's log). osascript is slow (~50–150ms/sample), but a
# spring across the display lasts several hundred ms, so a sweep is reliably sampled mid-flight.
_sample_mid_x() {
  local app="$1" n=$(( $2 * 10 )) x y w h
  for ((i = 0; i < n; i++)); do
    read -r x y w h <<<"$(real_window_frame "$app")"
    [ -n "$w" ] && echo $(( x + w / 2 ))
  done
}

# Seats & Pile slice 0: a slide must never drag a window across the display. The wrapping ring flips
# a parked window's edge (monocle: parked-left → parked-right) or un-parks it on the far side of its
# new seat (2-up: parked-left → R); MotionPolicy.sweepsAcross makes those moves snap. The fixture's 3
# windows reproduce both. Asserts on the "sweep-snap:" log line AND on the real frame never being
# sampled crossing the display.
scenario_no_park_sweep() {
  local ok=0 cp block app screen_w mid
  read -r screen_w _ <<<"$(_screen_size)"

  # Monocle: the left-parked window ends parked right — must never be seen on screen.
  cp=$(checkpoint); send_hotkey cols1; block=$(wait_for_cols 1 "$cp" 3) || { _fail_dump ""; return 1; }
  app=$(_parked_left_app "$block")
  if [ -z "$app" ]; then echo "    ✗ monocle: no window parked left" >&2; _fail_dump "$block"; return 1; fi
  cp=$(checkpoint); send_hotkey slideNext
  for mid in $(_sample_mid_x "$app" 1); do
    if [ "$mid" -gt 0 ] && [ "$mid" -lt "$screen_w" ]; then
      echo "    ✗ monocle: $app seen on screen (midX=$mid) while moving between park edges" >&2; ok=1; break
    fi
  done
  wait_for_line "sweep-snap: $app " "$cp" 3 >/dev/null || { echo "    ✗ monocle: no sweep-snap for $app" >&2; ok=1; }

  # 2-up: the left-parked window lands in R — must never be seen crossing the L seat.
  cp=$(checkpoint); send_hotkey cols2; block=$(wait_for_cols 2 "$cp" 3) || { _fail_dump ""; return 1; }
  app=$(_parked_left_app "$block")
  if [ -z "$app" ]; then echo "    ✗ 2-up: no window parked left" >&2; _fail_dump "$block"; return 1; fi
  cp=$(checkpoint); send_hotkey slideNext
  for mid in $(_sample_mid_x "$app" 1); do
    if [ "$mid" -gt 0 ] && [ "$mid" -lt $(( screen_w * 4 / 10 )) ]; then
      echo "    ✗ 2-up: $app seen crossing the left seat (midX=$mid) on its way to R" >&2; ok=1; break
    fi
  done
  block=$(wait_for_new_apply "$cp" 3) || { ok=1; }
  assert_eq "$(parse_slot_app "$block" R)" "${app%% *}" "2-up slideNext -> left-parked window lands in R" || { ok=1; _fail_dump "$block"; }
  wait_for_line "sweep-snap: $app " "$cp" 3 >/dev/null || { echo "    ✗ 2-up: no sweep-snap for $app" >&2; ok=1; }

  cp=$(checkpoint); send_hotkey cols3; wait_for_cols 3 "$cp" 3 >/dev/null || ok=1
  return "$ok"
}

# _slot_app_full <block> <L|C|R> — prints the FULL appName in that slot (verbose placement lines),
# unlike parse_slot_app's first word — needed to address the app ("Activity Monitor") by name.
_slot_app_full() {
  grep -E "slot=$2([[:space:]]|$)" <<<"$1" | head -1 | sed -E 's/^[^ ]+ +[●·] +//; s/ +slot=.*//'
}

_frontmost_app() {
  osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null
}

# Seats & Pile slice 0: focus that arrives from outside Strip (here an AppleScript `activate`, the
# same activation ⌘Tab/Dock/a click produce) into a visible side window is FOLLOWED — the focused
# slot moves to it with no window motion, Strip doesn't yank focus back, and J/K continue from it.
# Before the fix, handleExternalActivation returned early for managed windows: focus stayed on C in
# Strip's model, so J went C→L instead of R→C.
scenario_focus_follow() {
  local ok=0 cp block r_app c_app app before after after_f
  cp=$(checkpoint); send_hotkey cols3; block=$(wait_for_cols 3 "$cp" 3) || { _fail_dump ""; return 1; }
  # Put Strip's focus on C: J twice clamps at L, then K once.
  send_hotkey focusPrev; sleep 0.2; send_hotkey focusPrev; sleep 0.2
  cp=$(checkpoint); send_hotkey focusNext; block=$(wait_for_new_apply "$cp" 3) || return 1
  sleep 0.6 # let Strip's own focus hand-off to C land (focusSettleDelay) before activating from outside
  r_app=$(_slot_app_full "$block" R); c_app=$(_slot_app_full "$block" C)
  assert_eq "$(parse_focus_app "$block")" "${c_app%% *}" "setup: focus on C" || { _fail_dump "$block"; return 1; }

  cp=$(checkpoint)
  osascript -e "tell application \"$r_app\" to activate" >/dev/null 2>&1
  local ffn=""
  if wait_for_line "focus-follow: $r_app → slot R" "$cp" 3 >/dev/null; then
    ffn=$(grep -n -F "focus-follow: $r_app → slot R" "$STRIP_E2E_LOG" | tail -1 | cut -d: -f1)
  else
    echo "    ✗ no focus-follow to R ($r_app)" >&2; ok=1
  fi
  after=""
  if [ -n "$ffn" ]; then
    # Compare the focus-follow's own apply with the apply right before it — not the setup block: a
    # constraint-learning re-apply (another window's learned floor) can land in between.
    local start
    start=$(head -n "$ffn" "$STRIP_E2E_LOG" | grep -n "apply:" | tail -1 | cut -d: -f1)
    block=$(sed -n "${start},$((ffn - 1))p" "$STRIP_E2E_LOG")
    after=$(wait_for_new_apply "$ffn" 3) || { ok=1; after=""; }
  fi
  if [ -n "$after" ]; then
    assert_eq "$(parse_focus_app "$after")" "${r_app%% *}" "external activation -> focus on R" || { ok=1; _fail_dump "$after"; }
    for app in "${FIXTURE_APPS[@]}"; do
      before=$(parse_frame_for_literal_app "$block" "$app"); after_f=$(parse_frame_for_literal_app "$after" "$app")
      _frames_match "$before" "$after_f" 1 || { echo "    ✗ $app moved on focus-follow: ($before) -> ($after_f)" >&2; ok=1; }
    done
  fi
  sleep 0.8 # longer than focusSettleDelay: Strip must NOT hand focus back to C
  assert_eq "$(_frontmost_app)" "$r_app" "Strip leaves the externally-focused app frontmost" || ok=1

  cp=$(checkpoint); send_hotkey focusPrev; block=$(wait_for_new_apply "$cp" 3) || return 1
  assert_eq "$(parse_focus_app "$block")" "${c_app%% *}" "J after focus-follow steps R -> C" || { ok=1; _fail_dump "$block"; }
  return "$ok"
}

# Seats & Pile slice 0: a slide schedules a focus hand-off to the new center ~170 ms later
# (focusSettleDelay). A ⌘ keystroke (here ⌘Tab) or a click inside that gap must cancel it, or Strip
# activates the slid-to window AFTER the user switched away and steals their focus. A timing race by
# nature: each attempt sends ⌃⌥L then ⌘Tab D ms apart in one script and retries until Strip logs the
# cancel (proof the ⌘Tab landed inside the gap). MRU is set to [C app, L app] first, so ⌘Tab's
# target is the L app; the slid-to window is the R app. Clicks can't be driven here — hand-test those.
scenario_focus_handoff_cancel() {
  local ok=0 cp block l_app c_app r_app d hit=""
  cp=$(checkpoint); send_hotkey cols3; block=$(wait_for_cols 3 "$cp" 3) || { _fail_dump ""; return 1; }
  l_app=$(_slot_app_full "$block" L); c_app=$(_slot_app_full "$block" C); r_app=$(_slot_app_full "$block" R)
  for d in 0.05 0.03 0.08 0.1 0.04; do
    osascript -e "tell application \"$l_app\" to activate" >/dev/null 2>&1; sleep 0.4
    osascript -e "tell application \"$c_app\" to activate" >/dev/null 2>&1; sleep 0.6
    cp=$(checkpoint)
    osascript -e "tell application \"System Events\"
        key code 37 using {control down, option down}
        delay $d
        key code 48 using {command down}
      end tell" >/dev/null 2>&1
    if wait_for_line "focus hand-off cancelled ← ⌘ key" "$cp" 1 >/dev/null 2>&1; then hit=1; break; fi
    # Missed the gap (Strip already handed focus off): undo the slide and try a different spacing.
    send_hotkey slidePrev; sleep 0.8
  done
  if [ -z "$hit" ]; then
    echo "    ✗ the focus hand-off was never cancelled by ⌘Tab (5 attempts)" >&2
    echo "    frontmost now: $(_frontmost_app) (slid-to window: $r_app)" >&2
    return 1
  fi
  sleep 1 # well past focusSettleDelay: a stale hand-off would have activated $r_app by now
  assert_eq "$(_frontmost_app)" "$l_app" "⌘Tab target stays frontmost (not the slid-to $r_app)" || ok=1
  wait_for_line "focus-follow: $l_app → slot" "$cp" 2 >/dev/null \
    || { echo "    ✗ Strip didn't follow focus to the ⌘Tab target ($l_app)" >&2; ok=1; }
  return "$ok"
}

# Seats & Pile slice 0: focus arriving in a PARKED window. User-caused (⌘Tab here; a Dock or
# notification click in real use) → the window is swapped into the anchor slot (a two-entry ring
# swap, both snapped). Not user-caused (an AppleScript `activate`, an app activating itself) → nothing
# moves. Before the fix, ⌘Tab to a parked window left it off-screen while its app took the keyboard.
scenario_summon_parked() {
  local ok=0 cp block p_app a_app b_app line
  cp=$(checkpoint); send_hotkey cols2; block=$(wait_for_cols 2 "$cp" 3) || { _fail_dump ""; return 1; }
  p_app=$(grep "slot=PARKED" <<<"$block" | head -1 | sed -E 's/^[^ ]+ +[●·] +//; s/ +slot=.*//')
  a_app=$(_slot_app_full "$block" L); b_app=$(_slot_app_full "$block" R)
  [ -n "$p_app" ] || { echo "    ✗ 2-up: no parked window" >&2; _fail_dump "$block"; return 1; }

  # Not user-caused: no click or ⌘ key in the last second.
  sleep 1.2
  cp=$(checkpoint); osascript -e "tell application \"$p_app\" to activate" >/dev/null 2>&1
  wait_for_line "parked-focus: $p_app focused without user input — left parked" "$cp" 3 >/dev/null \
    || { echo "    ✗ app-caused focus into parked $p_app: no 'left parked' line" >&2; ok=1; }
  if log_has_since "$cp" "summon: $p_app" 1; then echo "    ✗ app-caused focus summoned $p_app" >&2; ok=1; fi

  # User-caused: MRU [A, P], then ⌘Tab → P.
  osascript -e "tell application \"$a_app\" to activate" >/dev/null 2>&1; sleep 0.6
  cp=$(checkpoint); send_key tab "command down"
  line=$(wait_for_line "summon: $p_app → center" "$cp" 3) \
    || { echo "    ✗ ⌘Tab to parked $p_app: not summoned" >&2; return 1; }
  assert_eq "$line" "${line%%summon*}summon: $p_app → center (swapped with $a_app)" "summon swaps with the anchor" || ok=1
  block=$(wait_for_new_apply "$cp" 3) || return 1
  assert_eq "$(parse_slot_app "$block" L)" "${p_app%% *}" "summoned window in the anchor slot (L)" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_slot_app "$block" R)" "${b_app%% *}" "R unchanged" || { ok=1; _fail_dump "$block"; }
  assert_eq "$(parse_slot_app "$block" PARKED)" "${a_app%% *}" "old anchor parked" || { ok=1; _fail_dump "$block"; }
  local expected
  expected=$(parse_frame_for_literal_app "$block" "$p_app") && _assert_real_frame "$p_app" "$expected" "$cp" 3 || ok=1
  sleep 0.6
  assert_eq "$(_frontmost_app)" "$p_app" "summoned app stays frontmost" || ok=1

  cp=$(checkpoint); send_hotkey cols3; wait_for_cols 3 "$cp" 3 >/dev/null || ok=1
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

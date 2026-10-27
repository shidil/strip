#!/bin/bash
# Overview search scenarios (⌃⌥F / `/`, typing, picks, ⌘Tab, native tabs). Same contract as
# scenarios.sh: return 0 on pass, 1 on fail after printing the mismatch.
#
# The oracle is the log. With STRIP_VERBOSE=1 (run.sh always sets it) every search key logs
#   search: state qlen=<n> results=<n> sel=<i> kind=<window|tab|none> app=<appName|->
# or `search: key ignored` (OverlayController.logSearchState) — counts and app names only, never
# the query text or a title. Session lines (`search: begin|pick|end`, `overview: open|closed (…)`)
# are always logged.
#
# Typing goes through System Events `keystroke`, which Strip's event tap reads like hardware typing
# (ASCII only — the tap doesn't compose dead keys/IME).

# _search_open — ⌃⌥F and wait for the session to start. Prints nothing; returns 1 on timeout.
_search_open() {
  local cp
  cp=$(checkpoint); send_hotkey toggleSearch
  wait_for_line "search: begin via=hotkey" "$cp" 3 >/dev/null || { echo "    ✗ ⌃⌥F: no 'search: begin'" >&2; return 1; }
}

# _search_close — Esc until the Overview is closed (Esc clears a query first, then closes).
_search_close() {
  local cp
  for _ in 1 2 3; do
    cp=$(checkpoint); send_key escape
    wait_for_line "overview: closed" "$cp" 1 >/dev/null 2>&1 && return 0
  done
  echo "    ✗ Esc never closed the Overview" >&2
  return 1
}

# _search_state <qlen> <since> — waits for the state line after the query reaches <qlen> characters
# and prints it.
_search_state() {
  wait_for_line "search: state qlen=$1 " "$2" 3
}

# _state_field <line> <name> — prints a key=value field of a `search: state` line (app= runs to EOL,
# since app names can contain spaces).
_state_field() {
  if [ "$2" == "app" ]; then
    sed -E 's/.* app=//' <<<"$1"
  else
    grep -oE "(^| )$2=[^ ]+" <<<"$1" | head -1 | sed -E "s/^ ?$2=//"
  fi
}

# _focused_app — the app holding keyboard focus per Strip's latest apply (re-applies 3-up to get one).
_focused_app() {
  local cp block
  cp=$(checkpoint); send_hotkey cols3
  block=$(wait_for_new_apply "$cp" 3) || return 1
  parse_focus_app "$block"
}

# ⌃⌥F opens straight into search; Esc on an empty query closes the whole Overview.
scenario_search_open_close() {
  local cp
  _search_open || return 1
  cp=$(checkpoint); send_key escape
  wait_for_line "search: end reason=close" "$cp" 3 >/dev/null || { echo "    ✗ Esc: no 'search: end reason=close'" >&2; return 1; }
  wait_for_line "overview: closed" "$cp" 3 >/dev/null || { echo "    ✗ Esc: Overview not closed" >&2; return 1; }
}

# `/` in the browse grid switches to search; ⌫ on an empty query goes back to the grid (Overview
# stays open); Esc in the grid closes it.
scenario_search_slash_and_back_to_grid() {
  local cp ok=0
  cp=$(checkpoint); send_hotkey toggleOverview
  wait_for_line "overview: open" "$cp" 3 >/dev/null || { echo "    ✗ ⌃⌥Space: Overview not open" >&2; return 1; }
  cp=$(checkpoint); send_key slash
  wait_for_line "search: begin via=slash" "$cp" 3 >/dev/null || { echo "    ✗ /: no 'search: begin via=slash'" >&2; ok=1; }
  cp=$(checkpoint); send_key delete
  wait_for_line "search: end reason=grid" "$cp" 3 >/dev/null || { echo "    ✗ ⌫ on empty query: no 'search: end reason=grid'" >&2; ok=1; }
  if log_has_since "$cp" "overview: closed" 1; then echo "    ✗ ⌫ to grid closed the Overview" >&2; ok=1; fi
  cp=$(checkpoint); send_key escape
  wait_for_line "overview: closed" "$cp" 3 >/dev/null || { echo "    ✗ Esc in grid: Overview not closed" >&2; ok=1; }
  return "$ok"
}

# Editing keys and selection: typing, ⌫, ⌥⌫ (word), ↑↓, Esc clears before it closes.
scenario_search_editing_and_selection() {
  local cp line ok=0
  _search_open || return 1
  cp=$(checkpoint); type_text "xyz"
  _search_state 3 "$cp" >/dev/null || { echo "    ✗ typing 'xyz': qlen never reached 3" >&2; ok=1; }
  cp=$(checkpoint); send_key delete
  _search_state 2 "$cp" >/dev/null || { echo "    ✗ ⌫: qlen not 2" >&2; ok=1; }
  cp=$(checkpoint); send_key delete "option down"
  _search_state 0 "$cp" >/dev/null || { echo "    ✗ ⌥⌫: word not deleted (qlen not 0)" >&2; ok=1; }

  # "e" is a subsequence of every fixture app name (Console, Activity Monitor, Preview).
  cp=$(checkpoint); type_text "e"
  line=$(_search_state 1 "$cp") || { echo "    ✗ typing 'e': no state line" >&2; _search_close; return 1; }
  if [ "$(_state_field "$line" results)" -lt 2 ]; then echo "    ✗ 'e' matched <2 results: $line" >&2; ok=1; fi
  assert_eq "$(_state_field "$line" sel)" "0" "new query selects the best hit" || ok=1
  cp=$(checkpoint); send_key down
  line=$(wait_for_line "search: state" "$cp" 3) && assert_eq "$(_state_field "$line" sel)" "1" "↓ moves the selection" || ok=1
  cp=$(checkpoint); send_key up
  line=$(wait_for_line "search: state" "$cp" 3) && assert_eq "$(_state_field "$line" sel)" "0" "↑ moves it back" || ok=1

  cp=$(checkpoint); send_key escape
  _search_state 0 "$cp" >/dev/null || { echo "    ✗ Esc with a query: not cleared" >&2; ok=1; }
  if log_has_since "$cp" "overview: closed" 1; then echo "    ✗ Esc with a query closed the Overview" >&2; ok=1; fi
  _search_close || ok=1
  return "$ok"
}

# Typing an app name ranks its window first; ↩ centers it (it takes keyboard focus) and closes.
scenario_search_type_and_pick() {
  local focused target query cp line block ok=0
  focused=$(_focused_app) || { echo "    ✗ couldn't read the focused app" >&2; return 1; }
  if [ "$focused" == "Preview" ]; then target="Console"; else target="Preview"; fi
  query=$(tr '[:upper:]' '[:lower:]' <<<"$target")

  _search_open || return 1
  cp=$(checkpoint); type_text "$query"
  line=$(_search_state "${#query}" "$cp") || { echo "    ✗ typing '$query': no state line" >&2; _search_close; return 1; }
  assert_eq "$(_state_field "$line" kind)" "window" "top hit kind for '$query'" || ok=1
  assert_eq "$(_state_field "$line" app)" "$target" "top hit app for '$query'" || ok=1

  cp=$(checkpoint); send_key return
  wait_for_line "search: pick kind=window rank=0 via=key" "$cp" 3 >/dev/null || { echo "    ✗ ↩: no window pick at rank 0" >&2; ok=1; }
  block=$(wait_for_new_apply "$cp" 3) || { echo "    ✗ ↩: no apply after the pick" >&2; return 1; }
  assert_eq "$(parse_focus_app "$block")" "$target" "picked window has focus" || { _fail_dump "$block"; ok=1; }
  wait_for_line "overview: closed \(pick\)" "$cp" 3 >/dev/null || { echo "    ✗ Overview not closed with reason pick" >&2; ok=1; }
  return "$ok"
}

# ⌘W during search is swallowed — it must not close the window behind the panel.
scenario_search_swallows_cmd_w() {
  local cp before after ok=0
  before=$(osascript -e 'tell application "System Events" to count windows of process "Console"' 2>/dev/null)
  _search_open || return 1
  cp=$(checkpoint); send_key w "command down"
  wait_for_line "search: key ignored" "$cp" 3 >/dev/null || { echo "    ✗ ⌘W: not swallowed (no 'search: key ignored')" >&2; ok=1; }
  _search_close || ok=1
  sleep 0.5
  after=$(osascript -e 'tell application "System Events" to count windows of process "Console"' 2>/dev/null)
  assert_eq "$after" "$before" "Console window count after ⌘W in search" || ok=1
  return "$ok"
}

# ⌘Tab passes through and closes the Overview — in search (reason=left) and in the browse grid —
# and the next key is no longer captured.
scenario_cmd_tab_leaves_overview() {
  local cp ok=0
  _search_open || return 1
  cp=$(checkpoint); type_text "co"
  _search_state 2 "$cp" >/dev/null || { echo "    ✗ typing 'co': no state line" >&2; ok=1; }
  cp=$(checkpoint); send_key tab "command down"
  wait_for_line "search: end reason=left" "$cp" 3 >/dev/null || { echo "    ✗ ⌘Tab in search: no 'search: end reason=left'" >&2; ok=1; }
  wait_for_line "overview: closed \(left\)" "$cp" 3 >/dev/null || { echo "    ✗ ⌘Tab in search: Overview not closed (left)" >&2; ok=1; }
  cp=$(checkpoint); send_key escape
  sleep 1
  if tail -n "+$((cp + 1))" "$STRIP_E2E_LOG" | grep -qE "search:|overview:"; then
    echo "    ✗ a key after ⌘Tab still reached Strip" >&2; ok=1
  fi

  cp=$(checkpoint); send_hotkey toggleOverview
  wait_for_line "overview: open" "$cp" 3 >/dev/null || { echo "    ✗ ⌃⌥Space: Overview not open" >&2; return 1; }
  cp=$(checkpoint); send_key tab "command down"
  wait_for_line "overview: closed \(left\)" "$cp" 3 >/dev/null || { echo "    ✗ ⌘Tab in the grid: Overview not closed (left)" >&2; ok=1; }
  return "$ok"
}

# Native AppKit tabs: TextEdit with two documents merged into one window (each tab is its own
# NSWindow). Picking the hidden tab must leave that tab showing — the regression: Strip centered the
# old, now-hidden window and AppKit switched the tab back. Adds a 4th managed window; cleans it up.
TABS_DIR="/tmp/strip-e2e-tabs"
_textedit_front_doc() {
  osascript -e 'tell application "System Events" to tell process "TextEdit" to get name of window 1' 2>/dev/null
}
scenario_search_native_tab_pick() {
  local cp front hidden query line block ok=0
  mkdir -p "$TABS_DIR"
  echo alpha >"$TABS_DIR/alpha.txt"
  echo beta >"$TABS_DIR/beta.txt"
  osascript -e 'tell application "TextEdit" to if it is running then quit' >/dev/null 2>&1
  sleep 0.5
  cp=$(checkpoint)
  open -a TextEdit "$TABS_DIR/alpha.txt" "$TABS_DIR/beta.txt"
  sleep 1.5
  osascript -e 'tell application "TextEdit" to activate' \
    -e 'tell application "System Events" to tell process "TextEdit" to click menu item "Merge All Windows" of menu "Window" of menu bar 1' \
    >/dev/null 2>&1 || { echo "    ✗ couldn't merge TextEdit windows into tabs" >&2; ok=1; }
  sleep 0.5
  _resize_window TextEdit
  click_menu "Re-tile / Re-scan"
  wait_for_total_count 4 "$cp" 8 >/dev/null || { echo "    ✗ Strip never managed the tabbed TextEdit window (4 total)" >&2; _native_tab_cleanup; return 1; }

  front=$(_textedit_front_doc)
  case "$front" in
    alpha.txt) hidden="beta.txt" ;;
    beta.txt) hidden="alpha.txt" ;;
    *) echo "    ✗ unexpected TextEdit front document '$front'" >&2; _native_tab_cleanup; return 1 ;;
  esac
  query="${hidden%.txt}"

  cp=$(checkpoint)
  _search_open || { _native_tab_cleanup; return 1; }
  wait_for_line "search: tabs TextEdit .* tabs=2" "$cp" 3 >/dev/null || { echo "    ✗ tab scan didn't find TextEdit's 2 tabs" >&2; ok=1; }
  type_text "$query"
  line=$(_search_state "${#query}" "$cp") || { echo "    ✗ typing '$query': no state line" >&2; _search_close; _native_tab_cleanup; return 1; }
  assert_eq "$(_state_field "$line" kind)" "tab" "top hit kind for hidden tab '$hidden'" || ok=1
  assert_eq "$(_state_field "$line" app)" "TextEdit" "top hit app" || ok=1

  cp=$(checkpoint); send_key return
  wait_for_line "search: native tab id=[0-9]+ → [0-9]+" "$cp" 3 >/dev/null || { echo "    ✗ ↩: shown tab window not adopted (no 'native tab A → B')" >&2; ok=1; }
  block=$(wait_for_new_apply "$cp" 3) || { echo "    ✗ ↩: no apply after the pick" >&2; ok=1; }
  [ -n "$block" ] && { assert_eq "$(parse_focus_app "$block")" "TextEdit" "picked tab's window has focus" || ok=1; }
  local presses
  presses=$(tail -n "+$((cp + 1))" "$STRIP_E2E_LOG" | grep -c "search: tab press")
  assert_eq "$presses" "1" "tab presses for one pick" || ok=1
  # The bug switched back ~200 ms after the pick; check the tab is still showing well after that.
  sleep 1.5
  assert_eq "$(_textedit_front_doc)" "$hidden" "TextEdit tab showing 1.5 s after the pick" || ok=1

  [ "$ok" == 0 ] || _search_close 2>/dev/null # a failed pick leaves the Overview open
  _native_tab_cleanup
  return "$ok"
}
_native_tab_cleanup() {
  local cp
  cp=$(checkpoint)
  osascript -e 'tell application "TextEdit" to if it is running then quit' >/dev/null 2>&1
  wait_for_total_count 3 "$cp" 5 >/dev/null || echo "    (cleanup: Strip didn't settle back at 3 windows)" >&2
  rm -rf "$TABS_DIR"
}

#!/bin/bash
# Drives Strip via its two reliable input surfaces: synthetic hotkey chords (System Events "key
# code") and status-bar menu clicks (System Events UI scripting). Strip's status menu lives under
# `menu bar 1` of the process (it's an LSUIElement accessory app — no app menu of its own, so this is
# NOT `menu bar 2` as it would be for a normal app).
#
# Key codes below are the v1-scope subset of the full map in MEASURING.md §5 (source of truth:
# Sources/StripKit/Input/HotkeyService.swift). Written as a `case`, not an associative array, so this
# also runs under Apple's stock /bin/bash 3.2 (no assoc-array support) if invoked directly.

# send_hotkey <name> — sends one of the named v1-scope chords via System Events.
send_hotkey() {
  local name="$1" code mods
  case "$name" in
    cols1) code=18; mods="control down, option down" ;;
    cols2) code=19; mods="control down, option down" ;;
    cols3) code=20; mods="control down, option down" ;;
    slideNext) code=37; mods="control down, option down" ;;
    slidePrev) code=4; mods="control down, option down" ;;
    focusNext) code=40; mods="control down, option down" ;;
    focusPrev) code=38; mods="control down, option down" ;;
    moveNext) code=37; mods="control down, option down, shift down" ;;
    movePrev) code=4; mods="control down, option down, shift down" ;;
    togglePin) code=35; mods="control down, option down" ;;
    releaseAll) code=29; mods="control down, option down" ;;
    focusWider) code=24; mods="control down, option down" ;;
    focusNarrower) code=27; mods="control down, option down" ;;
    taller) code=126; mods="control down, option down" ;;
    shorter) code=125; mods="control down, option down" ;;
    gapTighter) code=33; mods="control down, option down" ;;
    gapLooser) code=30; mods="control down, option down" ;;
    toggleOverview) code=49; mods="control down, option down" ;;
    toggleSearch) code=3; mods="control down, option down" ;;
    *)
      echo "send_hotkey: unknown command '$name'" >&2
      return 1
      ;;
  esac
  osascript -e "tell application \"System Events\" to key code $code using {$mods}" >/dev/null
}

# send_key <name> [modifiers] — one plain key, for the Overview and its search field (no ⌃⌥ chord).
# Names map to kVK_* codes (HotkeyService.swift). Modifiers are System Events terms, comma-separated,
# e.g. send_key tab "command down" for ⌘Tab.
send_key() {
  local name="$1" mods="${2:-}" code
  case "$name" in
    escape) code=53 ;;
    return) code=36 ;;
    delete) code=51 ;;
    up) code=126 ;;
    down) code=125 ;;
    tab) code=48 ;;
    space) code=49 ;;
    slash) code=44 ;;
    w) code=13 ;;
    *)
      echo "send_key: unknown key '$name'" >&2
      return 1
      ;;
  esac
  if [ -n "$mods" ]; then
    osascript -e "tell application \"System Events\" to key code $code using {$mods}" >/dev/null
  else
    osascript -e "tell application \"System Events\" to key code $code" >/dev/null
  fi
}

# type_text <text> — types plain text as real key events (System Events `keystroke`). Strip's search
# field reads it through its event tap like hardware typing. ASCII only: the tap doesn't compose dead
# keys or IME input.
type_text() {
  osascript -e "tell application \"System Events\" to keystroke \"$1\"" >/dev/null
}

# click_menu <top-level title> — clicks a top-level status-menu item (no submenu), e.g.
# click_menu "Overview" or click_menu "Show focus ring".
click_menu() {
  osascript -e "
    tell application \"System Events\"
      tell process \"Strip\"
        click menu bar item 1 of menu bar 1
        delay 0.3
        click menu item \"$1\" of menu 1 of menu bar item 1 of menu bar 1
      end tell
    end tell" >/dev/null
}

# click_submenu <top-level title> <submenu item title> — opens a submenu and clicks an item in it,
# e.g. click_submenu "Layout" "3-up (3)" or click_submenu "Minimap position" "Top".
click_submenu() {
  osascript -e "
    tell application \"System Events\"
      tell process \"Strip\"
        click menu bar item 1 of menu bar 1
        delay 0.3
        click menu item \"$1\" of menu 1 of menu bar item 1 of menu bar 1
        delay 0.3
        click menu item \"$2\" of menu 1 of menu item \"$1\" of menu 1 of menu bar item 1 of menu bar 1
      end tell
    end tell" >/dev/null
}

# real_window_frame <appName> — prints "x y w h" for the LIVE, on-screen AX frame of appName's
# window 1, queried directly via System Events — ground truth, independent of anything Strip logged.
# AX position/size are already top-left-origin, Y-down ("Quartz global", per CLAUDE.md/
# Coordinates.swift — the same space the AX API itself uses), the same space Strip's own log uses,
# so this is directly comparable with no coordinate conversion.
real_window_frame() {
  osascript -e "tell application \"System Events\" to tell process \"$1\" to get {position of window 1, size of window 1}" 2>/dev/null \
    | tr -d ','
}

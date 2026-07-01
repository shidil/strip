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
    *)
      echo "send_hotkey: unknown command '$name'" >&2
      return 1
      ;;
  esac
  osascript -e "tell application \"System Events\" to key code $code using {$mods}" >/dev/null
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

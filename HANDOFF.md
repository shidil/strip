# HANDOFF — start here (next: M5, overview + polish)

You're resuming the **Strip** macOS window-manager spike. **M0–M4 are done and user-confirmed.**
This doc gets you productive on **M5** fast. Read **PLAN.md** for the full picture; this is the
focused next-step guide.

## 1. Orient (5 min)

- Skim **PLAN.md** (goal, decisions, architecture, milestone progress, gotchas).
- Recall prior context: `mem_search "strip-wm-spike"` (engram has the detailed session memory).
- Confirm the toolchain still works:
  ```
  make test          # engine + state tests should pass (pure, no permissions)
  make open          # tiles your real windows + draws the overlay chrome; logs to /tmp/strip.log
  cat /tmp/strip.log
  ```
  `make open` (LaunchServices) is the only TRUSTED way to run — the raw binary from a shell isn't
  granted Accessibility. Logs go to `/tmp/strip.log` because open-launched apps have no stdout.
  **Note:** `apply()` early-returns on an empty ring, so the chrome only appears once ≥1 window is
  managed on the active display — open a few windows and Re-tile if you see only the hotkey log line.
- The "Strip Dev" signing identity already exists; the Accessibility grant persists across rebuilds.
  If trust ever breaks: `tccutil reset Accessibility com.spike.strip` then `make open` and re-grant.

## 2. Current state (M0–M4 complete)

Working and user-confirmed: window enumeration, the pure layout engine (monocle/2-up/3-up,
focus/equal emphasis, ring rotation, pin-aware assignment), smooth display-link spring animation,
the ⌃⌥ hotkey tap, **pinning** (⌃⌥P), and the full **M4 overlay chrome**:

- **Film rail** (bottom-center) — chip per window; white outline = focused, gold dot = pinned;
  click a chip to center that window.
- **Status pill** (top-center) — active app · layout · mode (Strip shift/Hybrid/Independent) ·
  transition (spring) · clock.
- **Help overlay** (⌃⌥/) — dimmed keyboard cheat-sheet.
- **Focus ring** — accent border tracking the focused window live (driven off the animator's
  display-link; no extra AX reads).
- **Real keyboard focus** follows the focused slot (`AXWindow.focus()` activates the owning app).

Overlay code lives in `Sources/StripKit/Overlay/` (`OverlaySnapshot`, `FilmRailView`,
`StatusPillView`, `HelpOverlayView`, `OverlayController`). `StripController.apply()` emits
`onRender(OverlaySnapshot)` (rail + pill) and `onFocusFrame(CGRect?)` (ring); `AppDelegate` wires
both to `OverlayController`.

## 3. M5 task — overview + polish

**Overview (⌃⌥Space):** a grid of cards, one per ring window (app name + accent placeholder — real
thumbnails need Screen Recording, deferred). Click a card to center + close. Prototype lines
**97-109**; the rail/overview card model is `overviewWindows` (lines 280-288).

- `HotkeyCommand.toggleOverview` is already emitted for ⌃⌥Space; the `.toggleOverview` case in
  `AppDelegate.handle` is still the stub (`Log.line("… coming in a later milestone")`) — wire it to
  a new `OverlayController.toggleOverview(...)`.
- Build it like the **help overlay**: a lazy full-screen `.popUpMenu`-level dimmed panel hosting a
  SwiftUI grid (`LazyVGrid`). Reuse the snapshot's `rail` items (id/letter/accent/active/pinned) for
  card content, or extend the snapshot if you want titles. Clicking a card → `onCenter(id)` + close
  (mirror `setCenter`'s "center + dismiss" from prototype line 286).
- A "Overview" status-menu item (like "Keyboard help…") is a nice mouse-testable extra.

**Spring polish:** confirm ⌃⌥T spring cycling reads well; tune presets. **User feedback: Track and
Pop feel best; Glide is optional.** Presets live in `Sources/StripKit/Animation/Spring.swift`.

### Verify M5
`make test` green; `make open`; open ≥4 windows; ⌃⌥Space shows the grid, clicking a card centers it
and closes the overview; ⌃⌥T cycles springs and the status pill's transition label updates.

### When done
Update **PLAN.md** (check off M5), update engram (`mem_save`, topic `strip-wm-spike`). That closes
out the planned spike — the strip concept, pinning, smooth motion, and the prototype's visual chrome
are all proven on real windows with only an Accessibility grant (no SIP, no scripting addition).

## 4. Don't relearn these (full list in PLAN.md "gotchas")

- Trust needs LaunchServices (`make open`); observe via `/tmp/strip.log` (truncated each launch).
- Keep signing identity stable (already set up) or you'll re-grant every build.
- Internal coords are Quartz (top-left); convert to Cocoa only for AppKit overlays
  (`Coordinates.toCocoa`) — the focus ring and all overlay panels rely on this.
- Terminal apps step during resize (character-cell quantization) — inherent, not a bug.
- Overlay chrome is borderless `.nonactivatingPanel`s at `.statusBar`; the focus ring is
  click-through (`ignoresMouseEvents`). Keep new overlays non-activating so they don't steal focus.

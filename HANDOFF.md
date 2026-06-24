# HANDOFF — Strip: spike → daily driver

> The spike (M0–M5) is **done and user-confirmed**: the film-strip *feel* is proven — smooth AX-only
> motion, pinning, layouts, overlay chrome, overview with real thumbnails, keyboard nav. See `PLAN.md`
> for that history. This doc is the **forward roadmap**: what turns the proven spike into something
> the author uses all day on a single ultrawide.

## North star

Strip runs all day and you forget it's there. Windows auto-arrange as you open/close them and launch/
quit apps; junk windows (dialogs, palettes, panels) stay out of the strip; nothing ever gets stranded
off-screen; it survives quit/crash/restart.

## Priorities (set 2026-06-24)

- **P0 — Auto-react.** The headline gap. Today Strip is *manual*: it only re-tiles when you ask. There
  are **no AX observers and no `NSWorkspace` launch/quit notifications** — the lone `Timer` is the
  permission gate (`AppDelegate.pollForTrust`). This is the single thing between "neat demo" and
  "forget it's running."
- **Single ultrawide** (BenQ EX3415R, 3440×1440). → **Multi-display and macOS Spaces are DEFERRED.**
- **Floating/ignore rules** — not optional: they are the required companion to auto-react.

## Where the work hooks in (verified seams)

- `StripController.refresh()` / `refreshAndApply()` — already idempotent, sticky-membership (a window
  stays managed while it *exists*, even parked; on-display test only gates *new* windows; orphans off
  every display are reclaimed). **Built to be driven by an event source.** Just needs calling on the
  right events instead of by hand.
- `AccessibilityService.allWindows()` — per-app AX enumeration. Its header comment (line ~5) already
  earmarks "live focus/create/destroy observation arrives in a later milestone."
- `AccessibilityService.isManageable()` — today minimal (role/subrole/min-size 80×80). This is where
  classification grows.
- `WindowAnimator` parks off-strip windows fully off the display edge — so a crash/quit *strands* them
  until the next launch's orphan-reclaim. M7 addresses this.

---

## Milestones

### M6 — Live & well-behaved (event-driven core)  ✅ DONE (2026-06-24)

The headline. Two halves that **must ship together** (auto-react without classification is a
regression — every dialog/palette gets tiled). **Both shipped; verified live** — windows re-tile on
open/close and app launch/quit with no hotkey, debounced into one reconcile, no flicker storm.

**What shipped:**
- `Accessibility/WindowObserver.swift` — per-app `AXObserver` (create/destroy/min/deminiaturize/
  focused/main) + `NSWorkspace` launch/terminate/activate/hide → one **75 ms trailing-edge debounced**
  `controller.refreshAndApply()`. Re-attaches on activation (covers launch-time AX-not-ready). Wired
  in `AppDelegate.start()`. **Deliberately does NOT observe move/resize** — that would feed the
  animator's own writes back into a reconcile storm; honoring user drags is M7.
- `AccessibilityService.classify()` → `managed | floating | ignored` (replaces `isManageable`).
  Conservative: floats non-standard subroles (dialogs/sheets/panels/palettes) and **non-resizable**
  windows (`AXWindow.isResizable` probes `AXUIElementIsAttributeSettable(kAXSize)`); ignores wrong
  role / minimized / sub-80px. Only `.managed` is tiled. No per-app denylist yet → M9.
- **New-window placement** (`StripState.insertManaged`, pure + tested): default `.focusCenter` slides
  a new window into the preferred *unpinned* slot (center→right→left) and focuses it; `.append` tucks
  it at the film's end. Customizable via `LayoutConfig.newWindowPlacement` (persisted; tolerant
  decoder so the new knob doesn't wipe old saved settings). `refresh()` only applies the policy to
  windows that appear *while running* — initial population lays out in on-screen order.

**Still open from M6 scope (minor):** when the *centered* window closes, center currently falls to
`ring.first` rather than the nearest neighbor — fine, but a nicer neighbor-pick is a small follow-up.

#### Original plan (kept for reference)

**6a — Event sources → one debounced reconcile**
- New `Accessibility/WindowObserver.swift`: owns a per-app `AXObserver` + run-loop source. Subscribe to:
  - `kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`
  - `kAXWindowMiniaturizedNotification` / `kAXWindowDeminiaturizedNotification`
  - `kAXFocusedWindowChangedNotification`, `kAXMainWindowChangedNotification`
  - (later) `kAXMovedNotification` / `kAXResizedNotification` for user drags — see M7
- `NSWorkspace.shared.notificationCenter`: `didLaunchApplication`, `didTerminateApplication`,
  `didActivateApplication`, `didHide/didUnhideApplication`. On launch → attach a fresh AXObserver to
  the new app's element; on terminate → tear it down.
- **Coalesce**: notifications fire in bursts (opening one app emits several). Debounce ~50–100 ms onto
  a single serial reconcile that calls `controller.refreshAndApply()`. Never reconcile per-event.
- Wire setup/teardown in `AppDelegate.start()`.

**6b — Window classification / ignore rules**
- Grow `isManageable` into a classifier returning `managed | floating | ignored`:
  - **ignored** (never touch): non-resizable windows (probe `AXUIElementIsAttributeSettable` for
    `kAXSizeAttribute`), `AXSheet`/dialog-ish subroles, popovers, sub-min-size, per-app denylist
    (media players, 1Password mini, system utilities, etc.).
  - **floating** (track but leave in place, so reconcile doesn't yank them).
  - **managed** (into the strip).
- Denylist keyed by bundle id; sourced from config in M9 (hardcode a sensible default set first).

**Acceptance:** open/close windows + launch/quit apps with no manual re-tile and no flicker storms;
dialogs/palettes/non-resizable windows are left alone.

### M7 — Resilience & escape hatch (won't strand you)

Auto-react means Strip is always touching your windows, so failure modes now matter.
- **Release-all** (hotkey + menu, e.g. ⌃⌥0): unmanage everything and un-park to sensible on-screen
  frames. An explicit "let go."
- **Quit/crash safety**: on `applicationWillTerminate`, un-park all parked windows back on-screen so a
  quit never leaves windows off the edge (today only the *next* launch reclaims them).
- **AX-drop recovery**: when AX writes to a window start failing (stale element, app relaunch), drop it
  from the ring instead of wedging the animator.
- **Respect user drags**: an `AXMoved`/`AXResized` *not* initiated by the animator means the user grabbed
  the window — re-absorb it into its slot or float it; don't fight back.

### M8 — Workspaces (multiple strips)

The niri model is *several* strips — the real organizing tool on one big display.
- N independent `StripState`s; switch with a hotkey; carry-focused-window-to-workspace.
- Inactive workspaces' windows parked off-screen (parking mechanism already exists).
- Per-workspace center / pins / layout.
- Likely a `WorkspaceManager` owning N states, or a workspace dimension on `StripController`.
- **Open question:** ⌃⌥1–3 are layout switches today; pick a non-conflicting binding (⌃⌥←/→? ⌃⌥⇧1–9?).

### M9 — Lives in the system

- **Launch at login** — `SMAppService.mainApp`; menu toggle.
- **Config file** — `~/.config/strip/` (TOML/JSON): hotkeys (today hardcoded in `HotkeyService`),
  spring presets, ignore denylist, default layout, workspace count.
- **Settings persistence** — remember cols/emphasis/spring/layout across restart. (Persist *settings*,
  not exact window placement — `CGWindowID` isn't stable across restart.)

---

## Deferred (revisit only if the setup changes)

- **Multi-display** — per-display strips, window-follows-active-display. Parked because: single ultrawide.
- **macOS Spaces + fullscreen apps** — windows on other Spaces aren't AX-enumerable without focusing
  them; large effort, low value for the current single-Space-per-display workflow.

## Verification (unchanged from spike)

- `make test` — engine correctness, no GUI.
- `make open`, then `cat /tmp/strip.log`; open 5–6 windows on the active display. (Trust requires the
  LaunchServices launch; logs go to `/tmp/strip.log`. See `PLAN.md` gotchas.)
- For M6: open/close windows and launch/quit apps **without touching a hotkey** and watch the log
  reconcile.

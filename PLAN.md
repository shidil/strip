# Strip — niri-style "film-strip" window manager for macOS (spike)

> **Resume doc.** This file is the durable source of truth for the project plan and milestone
> progress, so work can continue in a fresh session without the original chat history. For the
> immediate next step, also read **HANDOFF.md**. Engram memory: `mem_search "strip-wm-spike"`.

## Goal

Build the **real** macOS window manager (not a web port) that implements the **Strip** concept from
the Claude Design prototype in `wm-prototype/macos-window-manager-prototype/`: windows live on a
horizontal *film*, the focused window stays centered, neighbors flow past it ("the center slot never
moves"). This is a **spike to prove the strip concept feels good** — quality of motion/feel over
completeness.

The prototype HTML (`project/Strip Window Manager.dc.html` + `StripWindow.dc.html`) is the **design
spec**, not code to port literally. Its `geom()`/`resolve()`/`computeVM()` logic *was* ported (as the
layout engine); its visuals guide the M4 overlay chrome.

## Decisions (locked)

- **Swift + AppKit**, SwiftPM. Language mode v5 (avoids Swift6 Sendable friction with CF/AX types).
- **AX-only. No SIP disable. No scripting addition.** (Amethyst/AeroSpace/rift/OmniWM safe path.)
- **Single active display first.**
- **Pinning + layouts are core.** Animation matters most (it's the "feel").
- **Stable self-signed cert** ("Strip Dev") so the Accessibility grant survives rebuilds.

## Key technical finding (from researching `acsandmann/rift` + `BarutSRB/OmniWM`)

Smooth sliding of **real** app windows is achievable with **no SIP**, the way both projects do it:
1. `CADisplayLink`-paced loop (`NSScreen.displayLink`, 60/120 Hz).
2. Spring/ease an animated value toward a target.
3. Write `kAXPositionAttribute`/`kAXSizeAttribute` **every frame** via `AXUIElementSetAttributeValue`.
4. **Disable `AXEnhancedUserInterface`** on each target app so AppKit doesn't fight the moves.
5. Do AX writes **off the main thread** (per-app queue/run-loop) so a slow app can't stall the loop.
6. **"set size twice"** (`setSize; setPosition; setSize`) defeats min/max constraint clamping.

Windows teleport in many small steps per frame — there is **no continuous-transform** trick for
arbitrary app windows (that needs SIP). Private SLS/CGS used only for enumeration / focus / a WM's
own overlays — **never** to move managed app windows.

### Constraints this imposes
- Prototype's 3D film-feels (carousel/pop/fade use rotateY/translateZ/scale/opacity) **can't** apply
  to real windows. We implement **track** (translate + resize) and the `t` key cycles **spring
  presets** (Track/Pop/Glide) as the real-window stand-in.
- **Parked** (off-strip) windows can't fade — pushed fully off the display edge so they slide in/out.
- **Overview** real thumbnails need Screen Recording → deferred; M5 uses placeholder cards.
- **Terminal apps** (cmux/Ghostty) quantize size to character cells → they *step* during resize while
  per-pixel apps are smooth. Inherent to AX; accepted.

## Architecture / file map (what exists today)

```
Package.swift                      swift-tools 6.0; StripKit lib + Strip exe + StripKitTests; lang v5
Makefile                           build / bundle / run / open / test / clean / setup-signing
Resources/Info.plist               LSUIElement agent, bundle id com.spike.strip
scripts/setup-signing.sh           creates self-signed "Strip Dev" code-signing identity

Sources/Strip/main.swift           thin entry: .accessory NSApplication + AppDelegate

Sources/StripKit/
  AppDelegate.swift                menu-bar agent; permission gate; status menu (layout switching);
                                   wires HotkeyService -> StripController
  Logging.swift                    Log.line() -> /tmp/strip.log (open-launched runs have no stdout)
  StripController.swift            owns StripState + managed windows; refresh()/apply(); commands:
                                   setCols, setEmphasis/toggleEmphasis, rotate, focusMove,
                                   moveWindow, cycleSpring  (TODO: togglePin in M3)
  Model/
    Theme.swift                    accent palette + letter chips (FNV-1a stable hash per app)
    ManagedWindow.swift            id(CGWindowID)+AXWindow+app/title/frame
    StripState.swift               Slot{L,C,R}, Emphasis, StripState, slots/primarySlot, posMod()
  Accessibility/
    AXWindow.swift                 read/write AX frame; setFrame uses set-size-twice; raise()
    AccessibilityService.swift     ensureTrusted(); allWindows(); windows(on:)
    PrivateAPIs.swift              _AXUIElementGetWindow (no-SIP) -> CGWindowID identity
    EnhancedUI.swift               toggle AXEnhancedUserInterface per app
  Layout/
    Coordinates.swift              Quartz(top-left) <-> Cocoa(bottom-left); NSScreen.quartz*Frame
    SlotGeometry.swift             prototype geom() pixel constants / stage 1440x900, projected as
                                   FRACTIONS of the visible frame (fills screen, incl. ultrawide)
    StripLayout.swift              pure: resolve() + placements(in:) -> [WindowPlacement]
  Animation/
    Spring.swift                   SpringConfig (Track/Pop/Glide) + RectSpring (semi-implicit Euler)
    WindowAnimator.swift           CADisplayLink loop; per-app off-main AX writes; EnhancedUI off
                                   for motion duration; snap() for instant
  Input/
    HotkeyService.swift            CGEventTap behind ⌃⌥; kVK_* keycodes -> HotkeyCommand

Tests/StripKitTests/
  ThemeTests.swift                 stable hash / accent / letter
  StripLayoutTests.swift           ring rotation, wrap, pins, monocle, 2-up, geometry fidelity
                                   (1440x900 == prototype pixels), ultrawide scaling, parking
```

## Commands

**Build/dev loop**
```
make setup-signing   # ONE-TIME: create "Strip Dev" identity (already done on dev machine)
make test            # swift test (pure engine tests, no permission needed)
make bundle          # build + assemble + sign .build/Strip.app
make open            # bundle + launch via LaunchServices (TRUSTED; logs -> /tmp/strip.log)
make run             # bundle + run inner binary (NOT trusted from shell; build-check only)
```
**Hotkeys (behind ⌃⌥ = Control+Option)**
| Keys | Action | Status |
|---|---|---|
| ⌃⌥H / ⌃⌥L | slide film prev/next (rotate) | ✅ |
| ⌃⌥J / ⌃⌥K, ⌃⌥Tab | move focus between slots | ✅ |
| ⌃⌥⇧H / ⌃⌥⇧L | carry focused window along film (reorder) | ✅ |
| ⌃⌥1 / 2 / 3 | monocle / 2-up / 3-up | ✅ |
| ⌃⌥E | focus ↔ equal emphasis | ✅ |
| ⌃⌥T | cycle spring feel (Track/Pop/Glide) | ✅ |
| ⌃⌥P | pin/unpin focused slot | ✅ |
| ⌃⌥Space | overview | ⬜ M5 |
| ⌃⌥/ | help overlay (keyboard cheatsheet) | ✅ |

Status-bar menu (▦ Strip) also exposes: Re-tile, Layout submenu, Slide film, Quit.

## Critical gotchas (do not relearn)

1. **Trust requires LaunchServices.** Running the raw binary from a shell is NOT granted
   Accessibility (TCC attributes it to the parent shell). Use `make open`. Because that detaches
   stdout, the app logs to `/tmp/strip.log` — `cat`/`tail` it to observe.
2. **Stable signing.** Ad-hoc signing changes cdhash each build → grant invalidated. The "Strip Dev"
   cert keeps it stable. If you change signing identity: `tccutil reset Accessibility com.spike.strip`
   then `make open` and re-grant once.
3. Self-signed cert shows `CSSMERR_TP_NOT_TRUSTED` and is hidden by `security find-identity -v`
   (valid-only) — detect with `find-identity -p codesigning` WITHOUT `-v`. codesign + TCC accept it.
4. LibreSSL empty-password PKCS#12 fails `security import` ("MAC verification failed") — the setup
   script uses a throwaway p12 password.
5. Internal coords = **Quartz global** (top-left, Y down = what AX uses). Convert to Cocoa only for
   AppKit overlays (`Coordinates.swift`).

## Milestones & progress

- [x] **M0 — Skeleton & permission.** SwiftPM→.app, menu-bar agent, AX grant, window enumeration. ✅
- [x] **M1 — Static strip layout.** Pure engine port + place real windows into slots; 15 unit tests
      (incl. exact prototype-pixel fidelity). Menu-driven layout switching. ✅ user-confirmed.
- [x] **M2 — Smooth motion + hotkeys.** Display-link spring, off-main AX writes, EnhancedUI-off,
      ⌃⌥ hotkey tap. ✅ user-confirmed "works well, smooth". Fixed: re-scan dropping parked windows;
      restart stranding off-screen windows (orphan reclaim).
- [x] **M3 — Pinning.** ⌃⌥P pin/unpin focused slot. `togglePin()` ported as a *pure* mutating method
      on `StripState` (so the state transition is unit-tested without AppKit); `StripController.togglePin()`
      mutates + `apply()`; bound in `AppDelegate.handle` + a "Pin / unpin focused slot" status-menu item;
      `apply()` log line now lists pinned slots. 5 new `StripStateTests` (pin holds slot, focus leaves
      pinned slot, pinning center re-seats center, unpin restores flow, empty-slot no-op). ✅
- [x] **M4 — Overlay chrome** (first visual milestone; makes Strip look like the prototype). ✅
      SwiftUI views hosted in **borderless, non-activating `NSPanel`s** at `.statusBar` level. Live in
      `Sources/StripKit/Overlay/` (`OverlaySnapshot`, `FilmRailView`, `StatusPillView`, `HelpOverlayView`,
      `OverlayController`). `StripController.apply()` emits `onRender(OverlaySnapshot)` + `onFocusFrame`.
      - [x] **Film rail** (bottom-center): chips — letter (`Theme.letter`), accent (`Theme.accent`),
        dim when not assigned, white outline when active, gold pin dot when pinned; clicking a chip
        centers that window. Prototype lines **51-59** (+ pin dot 56). ✅ *Implemented:*
        `Sources/StripKit/Overlay/` — `OverlaySnapshot` (RailItem model), `FilmRailView` (SwiftUI),
        `OverlayController` (borderless `.nonactivatingPanel` at `.statusBar`, bottom-center of active
        screen). `StripController` emits `onRender(OverlaySnapshot)` after each `apply()`; chip click
        → `controller.setCenter(id)` (ported as pure `StripState.setCenter`, prototype 327-333).
        ✅ user-confirmed (screenshot: rail shows active outline + gold pin dot).
      - [x] **Focus ring**: accent-tinted border framing the focused window's live frame, tracking it
        as it animates. ✅ *Implemented:* sourced from the existing `WindowAnimator` display-link —
        `animator.focusedID` + `onFocusFrame` emit the focused window's `spring.current` each tick
        (and once on animate/snap/settle), so no extra AX reads or second display-link. `OverlayController`
        positions a click-through (`ignoresMouseEvents`) layer-bordered panel; border color = focused
        window's accent (from snapshot `activeAccent`). ✅ user-confirmed (tracks cleanly during slides).
      - [x] **Real keyboard focus follows the strip.** `AXWindow.focus()` (kAXMain + kAXFocused +
        kAXRaise + `NSRunningApplication.activate()`) replaces `raise()` in `apply()`, called only when
        the focused window changes (`lastFocusedId`). So ⌃⌥H/L · ⌃⌥J/K · rail-click route the keyboard
        to the focused window; spring-cycle / re-tile don't disturb it. ✅ user-confirmed.
      - [x] **Status pill** (top-center): activeApp · layout · mode · transition · clock. Prototype top
        bar **23-38**; labels like `modeLabel`/`transLabel`/`layoutLabel` (290-293). ✅ *Implemented:*
        `StatusPillView` (floating pill, since the real macOS menu bar owns the top edge). Snapshot
        fields computed in `StripController.railSnapshot`; mode = pin posture (Strip shift / Hybrid /
        Independent), transition = current spring name, clock refreshes per render. ✅ user-confirmed.
      - [x] **Help overlay** (⌃⌥/): keyboard cheatsheet. Prototype **76-95** / rows **310-320**. ✅
        *Implemented:* `HelpOverlayView` (dimmed full-screen modal, click/toggle to close), shown via
        `OverlayController.toggleHelp()`; `.toggleHelp` wired in `AppDelegate.handle` + "Keyboard help…"
        menu item. Chips show bare keys; subtitle notes the ⌃⌥ Mod chord. ✅ user-confirmed.
      - Pin **badge** is now visible (gold dot on the rail chip). ✅
- [ ] **M5 — Overview + polish.**
      - **Overview** (⌃⌥Space): grid of cards, one per ring window (app name + accent placeholder —
        real thumbnails need Screen Recording, deferred). Click a card to center+close. Prototype
        lines **97-109**. Wire the `.toggleOverview` stub in `AppDelegate.handle`.
      - Confirm ⌃⌥T spring cycling reads well; tune presets. **User feedback: Track and Pop feel
        best; keep Glide optional.**

## Prototype reference & feel notes (for M4/M5)

The prototype is the **visual spec** — re-read it when building chrome:
`wm-prototype/macos-window-manager-prototype/project/Strip Window Manager.dc.html` (+ `StripWindow.dc.html`).
Useful line ranges: status bar **23-38**, window strip/pin badge **40-49**, film rail **51-59**,
shortcuts button **61-63**, hint **65-74**, help overlay **76-95** (rows **310-320**), overview
**97-109**; logic `geom()` **165-179**, `resolve()` **181-202**, `computeVM()` **204-300**, label
helpers **290-293**, `onKey` map **390-418**; theme accents/letters/titles **131-134**. `StripWindow.dc.html`
holds the per-app window-body mockups (editor/terminal/browser/chat/mail/music/calendar) — reference
only for Overview card styling, not needed to manage real windows.

**Feel feedback (from M2 testing, user-confirmed):**
- Motion is smooth overall; **monocle is smoothest** (no resize). **Track and Pop springs feel best.**
- Per-pixel-resizing apps animate smoothly; **terminal apps (cmux/Ghostty) visibly step** because
  they quantize size to character cells — inherent to AX. *Possible future mitigation:* learn each
  app's size quantum and snap targets to it (OmniWM's `AXFrameApplicationLedger` approach), or hold
  size constant during a slide and resize only at rest. Not required for the spike.
- Default spring: critically-damped, stiffness **220** ("Track"); see `Spring.swift` presets.

**Environment (dev machine):** macOS 26.5.1 (Tahoe), Swift 6.3.2, Xcode present, arm64. Test display:
BenQ EX3415R, 3440×1440 ultrawide (good for exercising the fraction-based geometry / parking).

**Deeper research (in engram, topic `strip-wm-spike`):** rift = `acsandmann/rift` (Rust; animation in
`src/actor/reactor/animation.rs`, AX writes `src/actor/app.rs`), OmniWM = `BarutSRB/OmniWM` (Swift;
`Core/Animation/*`, `Core/Ax/*`, per-app CFRunLoop threads, `CADisplayLink` in `LayoutRefreshController`).

## Verification

- `make test` — engine correctness without a GUI.
- `make open`, then `cat /tmp/strip.log`; open 5–6 windows on the active display.
- Slide (⌃⌥H/L), layouts (⌃⌥1/2/3), emphasis (⌃⌥E), reorder (⌃⌥⇧H/L), spring (⌃⌥T).
- Re-tile while in monocle → all windows stay managed (no drops/strands).
- Sanity: no SIP, no scripting addition; runs with only the Accessibility grant.

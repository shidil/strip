# Strip — niri-style "film-strip" window manager for macOS

> **Source of truth.** This file is the durable record of the roadmap, milestone status, and the
> hard-won architecture/gotchas, so work can continue in a fresh session without the original chat
> history. Engram memory: `mem_search "strip-wm-spike"`.

## Goal

Build a **real macOS window manager** that implements the **Strip** concept: windows live on a
horizontal *film*, the focused window stays centered, and neighbors flow past it ("the center slot
never moves"). It began as a **spike to prove the strip concept feels good** (M0–M5, done) and is now
being turned into a **daily driver** (M6+).

The original design export is not distributed because its redistribution provenance was unclear.
Its `geom()`/`resolve()`/`computeVM()` concepts were ported into the tested Swift layout engine.

## North star

Strip runs all day and you forget it's there. Windows auto-arrange as you open/close them and
launch/quit apps; junk windows (dialogs, palettes, panels) stay out of the strip; nothing ever gets
stranded off-screen; it survives quit/crash/restart. Target setup: a **single ultrawide** (BenQ
EX3415R, 3440×1440). Multi-display and macOS Spaces are deliberately **deferred** (see *Deferred*).

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
Resources/Info.plist               LSUIElement agent, bundle id io.github.shidil.strip
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
    HotkeyService.swift            CGEventTap behind ⌃⌥; kVK_* keycodes -> HotkeyCommand;
                                   chordless Overview keys; search typing (`searchKey`)
  Search/
    WindowSearch.swift             pure: fuzzyMatch / rankSearch / query edits / pickTabGroup
  Accessibility/TabScanner.swift   bounded off-main AX walk for a window's tab bar; AXPress a tab

Tests/StripKitTests/
  ThemeTests.swift                 stable hash / accent / letter
  StripLayoutTests.swift           ring rotation, wrap, pins, monocle, 2-up, geometry fidelity
                                   (1440x900 == prototype pixels), ultrawide scaling, parking
```

### Verified seams (where new work hooks in)

- `StripController.refresh()` / `refreshAndApply()` — idempotent, sticky-membership (a window stays
  managed while it *exists*, even parked; the on-display test only gates *new* windows; orphans off
  every display are reclaimed). Built to be driven by an event source (see `WindowObserver`).
- `WindowObserver.swift` — per-app `AXObserver` + `NSWorkspace` notifications → one **75 ms
  trailing-edge debounced** `refreshAndApply()`. Deliberately does **not** observe move/resize as a
  reconcile trigger; user drags are handled via a global mouse bracket (M7). Notification list is
  `Self.notifications`.
- `AccessibilityService.classify()` → `managed | floating | ignored` (replaced `isManageable`). This
  is where window-classification rules grow (per-app denylist is still TODO → M9).
- `WindowAnimator` — the **only** thing that writes window frames; parks off-strip windows fully off
  the display edge. Exposes an `isDriving`/`drivenUntil` handshake so the observer can tell the
  animator's own `AXMoved`/`AXResized` from a real user drag.
- `AppDelegate.start()` — wires `HotkeyService` → `StripController`, sets up/tears down the observer,
  and un-parks all windows on `applicationWillTerminate`.

## Commands

**Build/dev loop**
```
make setup-signing   # ONE-TIME: create "Strip Dev" identity (already done on dev machine)
make test            # swift test (pure engine tests, no permission needed)
make bundle          # build + assemble + sign .build/Strip.app
make open            # bundle + launch via LaunchServices (TRUSTED; logs -> /tmp/strip.log)
make run             # bundle + run inner binary (NOT trusted from shell; build-check only)
make e2e             # hotkey/menu integration smoke suite — see TESTING.md (needs Accessibility + clean desktop)
make e2e-vm          # same suite, isolated in a Tart VM — see TESTING.md (one-time setup required)
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
| ⌃⌥Space | overview (real thumbnails) | ✅ |
| ⌃⌥0 | release-all / toggle-suspend (escape hatch) | ✅ |
| ⌃⌥/ | help overlay (keyboard cheatsheet) | ✅ |

Status-bar menu (▦ Strip) also exposes: Re-tile, Layout submenu, Slide film, Overview, Release-all, Quit.

## Critical gotchas (do not relearn)

1. **Trust requires LaunchServices.** Running the raw binary from a shell is NOT granted
   Accessibility (TCC attributes it to the parent shell). Use `make open`. Because that detaches
   stdout, the app logs to `/tmp/strip.log` — `cat`/`tail` it to observe.
2. **Stable signing.** Ad-hoc signing changes cdhash each build → grant invalidated. The "Strip Dev"
   cert keeps it stable. If you change signing identity: `tccutil reset Accessibility io.github.shidil.strip`
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
- [x] **M5 — Overview + polish.** ✅
      - [x] **Overview** (⌃⌥Space): dimmed grid of cards (on the active display), one per ring window
        (now showing **real window thumbnails** via ScreenCaptureKit, falling back to an
        app-name + title accent placeholder). Active window framed by its accent; pinned windows get a "PINNED" badge. Click a
        card → center + close. Prototype lines **97-109** / `overviewWindows` **280-288**.
        *Implemented:* `Sources/StripKit/Overlay/OverviewView.swift`;
        `OverlayController.toggleOverview()` (lazy `.popUpMenu`-level panel like the help overlay,
        rebuilt from the cached `lastSnapshot` and kept in sync while open); `.toggleOverview` wired
        in `AppDelegate.handle` + an "Overview" status-menu item. `RailItem` extended with
        `appName`/`title` for card labels. Card click reuses the existing `onCenter` → `setCenter(id)`.
        Verified live (user screenshot confirmed). **Two layout/feel decisions worth keeping:**
        - **Centered rows, not `LazyVGrid`.** A fixed-column grid left-aligns the last partial row;
          instead the cards are chunked into rows of 3 (the prototype's natural wrap), each row a
          centered `HStack(maxWidth: .infinity)`, so a lone trailing card centers under the row above.
        - **Real thumbnails via ScreenCaptureKit (no longer deferred).** `Overlay/WindowThumbnailer.swift`
          captures each ring window with `SCScreenshotManager.captureImage` + `SCContentFilter(desktopIndependentWindow:)`,
          matching `SCWindow.windowID` to our `CGWindowID` (so occluded windows still render their own
          content — the win over the obsoleted `CGWindowListCreateImage`). `Overlay/ThumbnailStore.swift`
          (an `ObservableObject` keyed by `CGWindowID`) captures **on overview open** and merges results
          so reopens paint stale thumbnails instantly; `OverviewCard.body_` shows `Image(decorative:scale:2)`
          when present, else the accent gradient. Each capture buffer is sized to the **window's own
          aspect** (from `SCWindow.frame`) so the image has no baked-in letterbox bars. To avoid bars in
          the card too, cards are **uniform-height, variable-width**: all share `bodyHeight` (312pt) and
          take `width = bodyHeight × aspect` (aspect from `RailItem.aspect`, clamped 0.6–2.2), so rows
          stay tidy like a justified gallery and the thumbnail fills the body (`.aspectRatio(.fit)`,
          Mission-Control style). Capture resolution is bounded by the widest card (688×312pt) for crispness. Screen Recording is a **second TCC grant** — requested
          once on first open (`CGPreflight/RequestScreenCaptureAccess`), placeholders shown until granted.
          Like Accessibility the grant attributes to the launching process, so `make open` + stable signing
          covers it; re-launch via `make open` after granting. `includeChildWindows` was dropped (it's
          macOS 14.2+, package targets 14.0). Fully-parked off-screen windows may not capture → placeholder.
        - **Behind-window blur via the window server (`CGSSetWindowBackgroundBlurRadius`).** The
          prototype's `backdrop-filter: blur` over the windows behind is achievable and is the chosen
          look. Two dead ends first: (1) `NSVisualEffectView(.behindWindow)` blurs but its radius is
          *fixed and heavy* (windows behind become unrecognizable smears) — and it falls back to opaque
          grey on a non-activating panel unless you force `state = .active` *and* "Reduce transparency"
          is off; (2) a raw private `CABackdropLayer` captures only *within* its own window, so over a
          transparent panel it blurs nothing. The working path is the private SkyLight call
          `CGSSetWindowBackgroundBlurRadius(CGSMainConnectionID(), windowNumber, radius)` (no SIP;
          declared in `PrivateAPIs.swift` as `setWindowBackgroundBlur(window:radius:)`), applied to the
          overview panel *after* it's on screen so it has a valid window number. The radius is tunable —
          settled on **22** (`OverlayController.overviewBlurRadius`); ~8–12 reads sharper, ~30–50 ≈
          NSVisualEffectView. The SwiftUI view lays only a faint `Color(8,8,12).opacity(0.10)` tint that
          the blurred windows show through (it also gives the panel the bit of alpha the window-server
          blur composites under). Caveat: with "Reduce transparency" *on*, the OS drops the blur — that's
          a user setting, not a bug.
      - [x] **Spring polish.** Presets kept as-is — user feedback already confirmed **Track and Pop
        feel best**, and the cycle order `[track, pop, glide]` puts those two first with **Glide last
        (optional)**. ⌃⌥T cycling updates the status pill's transition label. No retune warranted.

> **M0–M5 = the spike, done and user-confirmed.** From here Strip becomes a daily driver.

- [x] **M6 — Live & well-behaved (event-driven core).** ✅ DONE 2026-06-24, verified live. The
      headline gap: Strip was *manual* (re-tiled only on command). Two halves shipped together
      (auto-react without classification is a regression — every dialog gets tiled):
      - `Accessibility/WindowObserver.swift` — per-app `AXObserver` (create/destroy/min/deminiaturize/
        focused/main) + `NSWorkspace` launch/terminate/activate/hide → one **75 ms trailing-edge
        debounced** `refreshAndApply()`. Re-attaches on activation (covers launch-time AX-not-ready).
        Deliberately does **not** observe move/resize (would feed the animator's own writes back into a
        reconcile storm — user drags are M7).
      - `AccessibilityService.classify()` → `managed | floating | ignored` (replaced `isManageable`):
        floats non-standard subroles (dialogs/sheets/panels/palettes) and **non-resizable** windows
        (`AXWindow.isResizable` probes `AXUIElementIsAttributeSettable(kAXSize)`); ignores wrong
        role / minimized / sub-80px. Only `.managed` is tiled. Per-app denylist deferred → M9.
      - **New-window placement** (`StripState.insertManaged`, pure + tested): default `.focusCenter`
        inserts a new window into the film **right after the focused window** (niri-style) and focuses
        it; previous focus flows to the slot on its left. `.append` tucks it at the film's end.
        `LayoutConfig.newWindowPlacement` (persisted, tolerant decoder). Applies only to windows that
        appear *while running*; initial population lays out in on-screen order.
      - **Closing the centered window** hands center to the flanking window — left slot first, then
        right (`StripController.neighborOfClosedCenter`, pure + tested); falls back to `ring.first`.
- [x] **M7 — Resilience & escape hatch.** ✅ DONE 2026-06-24, verified live. Auto-react means Strip is
      always touching windows, so failure modes matter. Four independently-shippable slices:
      - **Release-all** (⌃⌥0) — toggle-suspend escape hatch: un-parks every off-screen window to a
        centered/cascaded on-screen frame, then suspends management (refresh/apply no-op) so windows
        stay put. ⌃⌥0 again — or any explicit layout/nav command — resumes and re-tiles.
        `StripController.releaseAll`/`resume`/`unparkStranded`; `unparkFrame` pure + tested.
      - **Un-park-on-quit** — `applicationWillTerminate` stops the observer then synchronously
        (`unparkAllOnScreen`, no animator — the display link won't tick during termination) writes
        every parked window back on-screen, so quitting never strands a window.
      - **AX-drop recovery** — `AXWindow.setFrame` surfaces `AXError`; `WriteFailureTracker` (pure +
        tested) counts per-window consecutive failures and, after a hard `.invalidUIElement` or N soft
        failures, fires `onWindowLost` → the controller drops the dead window instead of wedging the
        animator on a stale element (app crash/relaunch).
      - **Respect user drags** (the crux) — a **global left-button bracket** (`WindowObserver`)
        suspends management while the mouse is held and flushes on release. A user **move** of a tiled
        window snaps it back; a **resize of the dominant window** is *kept* by inverting its frame into
        the sizing knobs (`DragResolver`, pure + tested: width → `focusRatio`/`monocleWidthFraction`,
        height → `heightFraction`); non-dominant resizes snap back. The animator distinguishes its
        **own** writes from user drags via the `isDriving`/`drivenUntil` handshake, re-seats a dragged
        window from its live frame (`forget`), and returns it with a one-shot `SnapBack` spring.
        Size-quantizing apps (terminals — `SteppingApps`, pure + tested) snap rather than spring.
      - **Known residual (not a Strip defect):** heavyweight apps (e.g. cmux) beachball/step while
        *you* drag their native resize handle — their own AX-resize slowness. Per-app handling → M9.
- [ ] **M8 — Workspaces (multiple strips).** ← **NEXT.** The niri model is *several* strips — the real
      organizing tool on one big display.
      - N independent `StripState`s; switch with a hotkey; carry-focused-window-to-workspace.
      - Inactive workspaces' windows parked off-screen (parking mechanism already exists).
      - Per-workspace center / pins / layout.
      - Likely a `WorkspaceManager` owning N states, or a workspace dimension on `StripController`.
      - **Open question:** ⌃⌥1–3 are layout switches today; pick a non-conflicting binding
        (⌃⌥←/→? ⌃⌥⇧1–9?).
- [ ] **M9 — Lives in the system.**
      - **Launch at login** — `SMAppService.mainApp`; menu toggle.
      - **Config file** — `~/.config/strip/` (TOML/JSON): hotkeys (today hardcoded in `HotkeyService`),
        spring presets, ignore denylist, default layout, workspace count.
      - **Settings persistence** — remember cols/emphasis/spring/layout across restart. (Persist
        *settings*, not exact window placement — `CGWindowID` isn't stable across restart.)
- [ ] **M10 — 2-D film (vertical columns).** Each horizontal slot becomes a niri-style *column* — a
      vertical sub-strip of windows you slide on the **y-axis** — with both axes live at the same time
      in **one** workspace. (Distinct from M8: switching M8 workspaces changes *everything*; here the
      x-strip stays and you slide windows up/down within a slot.) Turns the 1-D ring into a 2-D grid.
      - Pure model: `StripState` ring → 2-D (each slot holds a column of windows).
      - Layout: `SlotGeometry` gains per-column **y-distribution** (it distributes width across X only today).
      - Nav: add vertical keys (up/down within a column) alongside J/K.
      - Minimap: render columns, not a flat row.
      - Feasible on AX-only (still just move/resize of our own windows); **L** effort.

## Backlog — triaged ideas (from `IDEAS.md`, triaged 2026-06-30)

All feasible on the AX-only platform (none need 3-D / per-window opacity / dragging real windows — they
act on Strip's own overlay or its ring model, or reuse the M5 ScreenCaptureKit capture). Effort: S/M/L.
The two milestone-sized/ambiguous ones were promoted/clarified: vertical columns → **M10** above;
"swap to center/right slot" → swap-with-neighbor (below). Raw wording is preserved in `IDEAS.md`.

**Minimap (film rail) polish** — the rail panel is already interactive (`.statusBar`, `onTapGesture`):
- ~~**App icons instead of letter chip** (S)~~ — ✅ shipped 2026-07-01: `ManagedWindow.icon`
  (`NSRunningApplication(processIdentifier: ax.pid)?.icon`) threaded through `RailItem`/`railSnapshot`;
  `RailChip` shows the real app icon over the existing accent-filled backdrop, falling back to the
  letter chip when `icon` is `nil` (e.g. app already quit, or a synthetic test `RailItem`).
- ~~**Window previews on hover or hotkey** (M)~~ — ✅ shipped 2026-07-01 (hover trigger): reuses
  `ThumbnailStore`/`WindowThumbnailer`. `FilmRailView`'s `.onHover` → `OverlayController.handleChipHover`
  debounces ~300ms, then captures just that window and shows `RailPreviewView` in a lazily-created
  panel positioned adjacent to the whole rail (not per-chip — avoids new SwiftUI coordinate-space
  plumbing), on the screen-interior side of whichever `RailEdge` the rail is anchored to. **Fixed a
  latent bug in the reused pipeline along the way:** `ThumbnailStore.refresh` unconditionally evicted
  any cached image not in the passed `ids` — fine for Overview (which always passes the *complete*
  ring), but a single-window hover request would have silently wiped every other cached Overview
  thumbnail. Added `evictOthers: Bool = true` (Overview keeps the default; hover passes `false`).
  Caveat carried over from M5: parked/minimized windows can't capture → placeholder. ✅ user-confirmed
  live (screenshot: preview renders above the rail, accent-bordered, real thumbnail).
- ~~**Reposition the minimap** (S–M)~~ — ✅ shipped 2026-07-01, scoped up to a **true vertical rail**
  (not just corner-anchoring) per user decision during planning. New `RailEdge` (`bottom`/`top`/`left`/
  `right`, persisted in `PersistedSettings` exactly like `focusRingEnabled`) drives both
  `OverlayController.railOrigin` (screen placement; `.top` offsets below the status pill) and
  `FilmRailView`'s container axis (`HStack` for top/bottom, `VStack` for left/right — the "FILM" label
  stays unrotated, a deliberate simplification). Status-bar menu → "Minimap position" submenu calls
  `StripController.setRailEdge`. Live-verified on all 4 edges via screenshot (vertical stacking on
  left/right, no overlap with the status pill on top, correct default on bottom).
- ~~**Overview-trigger button in the minimap** (S)~~ — ✅ shipped 2026-07-01: a small grid-glyph button
  appended to the rail (trailing end of the `HStack`/`VStack`) calls the existing
  `OverlayController.toggleOverview()` directly (no new plumbing needed — both live on the same class).
  The rail mirrored inside Overview itself (`OverviewView`) always stays horizontal/bottom regardless
  of the live rail's `RailEdge`, and its button closes Overview instead of reopening it.

**Mouse / Dock interaction:**
- **Follow OS/Dock focus → re-center** (M) — `WindowObserver` already receives `kAXFocusedWindowChanged`
  / `kAXMainWindowChanged` / `didActivateApplication` (today they feed a reconcile, not a re-center);
  re-center the focused ring window. Watch-outs: Strip's own focus change must not re-trigger
  (self-suppression already exists), and ⌘-Tab churn could slide the strip on every app-switch.
- **Drag-rearrange windows in the minimap** (L) — rail drag → ring permutation in `StripState` → re-tile.
  Heaviest minimap interaction; only reorders our model, no AX drag of real windows. Can build on the
  ring-swap primitive `StripState.moveFocused` below.
- **Modifier-click swap in the minimap** (S–M) — rail click + modifier → swap ring positions. Can build
  on the ring-swap primitive `StripState.moveFocused` below.

**Navigation / commands:**
- **Auto-demote `cols` when learned size floors don't fit** (M, semantic decision) — the size-constraint
  work (2026-07-02, see BUGS.md Fixed "real window size disagrees") sizes slots around each window's
  learned `SizeConstraint` floors/ceilings; when the floors alone exceed the usable width the solver
  emits them verbatim and the row spills off the display edges (logged `constraint-unsatisfiable`) —
  the honest last resort. The alternative — automatically dropping to fewer columns (niri-style
  "park what doesn't fit") — changes layout semantics the user didn't ask for, so it was deliberately
  left out. If spill turns out to be common in daily use, revisit: `StripController.apply()` already
  detects the condition (`spillsOffDisplay`), so demotion would be a targeted `state.cols` adjustment
  gated on it.
- **Window & tab search (Spotlight-style, inside Overview)** (M → L with tab sources) — 🧪 **prototype
  on `feat/window-search` (2026-10-26), hands-on tested by the user: success.** Goal: one keyboard interface to
  every pane you can reach — windows *and* the tabs inside them — built on the Overview grid.
  - **Feasibility findings (probed live 2026-10-26, read-only AX walk of each window, skipping
    `AXWebArea`):**
    | App | Tabs via AX? | Notes |
    |---|---|---|
    | Firefox | ✅ | `AXTabGroup` → `AXRadioButton`/`AXTabButton`, title + `AXValue` selected + `AXPress`. 36 nodes, 15–20 ms/window. |
    | Firefox sidebar | ⚠️ false positive | A **second** `AXTabGroup` (Bookmarks/History/Customize sidebar), same roles. Disambiguated by `pickTabGroup`: the real bar is the group whose selected tab title matches the window title. |
    | WezTerm | ❌ | Custom-drawn tab bar, nothing in AX (`[1/2]` only in the title). Needs a `wezterm cli list`/`activate-tab` provider. |
    | Slack, Reviu | – | No tabs. Reviu: 6 nodes took 20 ms — cost is **per-app AX latency, not tree size**. |
    | Terminal.app, Finder (native NSWindow tabs) | ✅ user-verified | `AXTabGroup` of radio buttons. Background native tabs are separate hidden NSWindows — `refresh()` already drops them. |
    | Safari | ✅ after fix | **Different shape:** tab bar is an `AXOpaqueProviderGroup` ("Tab bar, N tabs") of `AXRadioButton`/`AXTabButton`; its only `AXTabGroup` wraps the *page content* (zero buttons — the prototype found it and read 0 tabs). Fixed by finding tab *buttons* (`isTabButton`) and treating their parent as the bar. |
    | Chromium-family | expected ✅, **unverified** | Tab strip is native/views AX; must not force `AXEnhancedUserInterface`/web AX (expensive). |
    | Electron editors (VS Code tabs) | ❌ practical | Tree only with `AXManualAccessibility` (heavy). Out of scope. |
  - **What the prototype does:** ⌃⌥F opens Overview straight into search; `/` inside Overview switches
    to search. Typing filters the grid to matching windows (best match first) and shows a ranked
    window + tab list in a Spotlight-style panel. ↑↓/Tab/⌃N⌃P select, ↩ goes (tab hit: `AXPress` the
    tab, then `setCenter(window)`), ⌫ on an empty query → back to the grid, Esc clears then closes.
  - **Decisions taken for the prototype (revisit with feedback):**
    1. **Typing goes through the existing event tap**, not a key-capable text field — keeps the
       "Strip never takes focus" invariant; layout-correct via `keyboardGetUnicodeString`. Cost: no
       IME / dead-key composition. Fallback if needed: a key-capable non-activating panel with a real
       `NSTextField` (needs a spike: focus churn → `WindowObserver`, restoring key on close).
    2. **Key conflicts:** while searching, *all* plain keys are text (h/j/k/l and Space type), ⌃⌥
       chords still work, ⌘⌫ clears, ⌘V pastes, ⌘Tab/⌘`/⌘Space pass through, and every other ⌘
       shortcut is swallowed (⌘W/⌘Q would hit the app *behind* the panel). Browse-mode hjkl
       is untouched because search is entered explicitly (`/` or ⌃⌥F).
    3. **Grid while searching = filter, not dim** (non-matching cards hidden, matches reordered by rank).
    4. **Matching:** fzf-style subsequence scoring per whitespace token; every token must hit the
       title, app name (×¾) or — for tabs — the parent window title (×⅓). Window +4 over an equal tab;
       the active tab of a window is not listed separately (the window row covers it).
    5. **Tab scan only when search starts**, per-app serial queues off-main, results stream in;
       BFS bounded (depth 9, 400 nodes incl. frontier, 250 ms, 0.15 s per-call AX timeout so a hung
       app can't hold its queue) and never enters `AXWebArea`/tables/outlines/lists. Tabs are dropped
       at session end (stale elements) and a generation token orphans late scan callbacks. A tab pick
       goes through `StripController.centerTab`: activation pre-suppressed, press on the animator's
       per-pid AX queue so it's ordered before the re-center's frame writes and focus hand-off.
       Walks the elements Strip already holds — never re-enumerates `kAXWindows` (main-bound).
  - **Code:** pure `Search/WindowSearch.swift` (`fuzzyMatch`, `rankSearch`, `applying(QueryEdit)`,
    `pickTabGroup`) + `searchKey(...)` in `HotkeyService.swift` — all in `WindowSearchTests`;
    `Accessibility/TabScanner.swift` (walk + press, `tabScan` signpost); `Overlay/SearchModel.swift`,
    `Overlay/SearchPanelView.swift`; wiring in `OverlayController` (`toggleSearch`/`beginSearch`/
    `handleSearchKey`) and `AppDelegate`.
  - **Feedback instrumentation:** `/tmp/strip.log` lines `search: begin|pick|end|tabs|tab scan done`
    carry counts, ranks and query *length* only — never query text or tab titles.
    `scripts/search-feedback.sh` summarizes them (pick rate, rank-of-pick, tabs found, scan ms).
  - **Feedback round 1 (2026-10-26):** ⌃⌥F, `/`, ⌫-to-grid, ↑↓ selection, window and tab picks all
    worked as expected; tabs showed for Firefox, Terminal, Finder; **not Safari** (fixed above).
    `search-feedback.sh`: 18 sessions, 11 picks (61%) — **8 tab / 3 window**, pick rank #0=7 #1=1
    #2=2 #5=1, avg query 3.5 chars; tab scan avg 35.8 ms / max 126.6 ms, avg 4.8 tabs, 1 ambiguous
    window. Tabs are the main use — the feature's value is tab reach, not window search.
  - **Wish: preview a tab's content in the card while ↑↓ through tab results.** Feasibility (probed):
    - A background tab's content **isn't capturable**. ScreenCaptureKit lists no window for it
      (browser tabs share one window; hidden native-tab NSWindows are off-screen and fail to
      capture). Only the visible tab renders.
    - **Peek works and is fast:** AXPress the tab → content visible in a capture in **41–77 ms**
      (Safari 72/77 ms, Firefox 41/51 ms, warm tabs, 2 runs each), capture ~15 ms. Restoring the
      original tab is another AXPress. Side effects: the real tab switches behind the blur;
      unloaded/discarded tabs reload (network, slower); media may start; parked (off-display)
      windows may not capture.
    - Zero-side-effect alternative: **cache** a thumbnail per (window, tab title) whenever that tab
      is seen active — stale, and empty for tabs never seen.
    - **Native window tabs can't be peeked safely:** each AppKit tab is its own NSWindow, so a switch
      swaps the on-screen `CGWindowID` and the strip would re-adopt windows under the Overview.
      Detected by shape (`tabsAreSeparateWindows`: `AXTabGroup` directly under `AXWindow`, probed
      with a two-tab NSWindow) → those cards say "No preview for native tabs".
    - **User decision: peek, then restore** (2026-10-26). 🧪 Prototyped: selection rests 120 ms on a
      tab result → `StripController.pressTab` (suppressed, animator AX queue) → re-capture the window
      at +90 ms and +300 ms (`ThumbnailStore.captureNow`) → card shows it with a "Tab preview · …"
      caption. Moving to another window's result, selecting a window result, ⌫-to-grid, Esc or
      closing restores every peeked window's original tab; ↩ on a tab keeps it. Which presses to make
      is the pure `peekPresses` (tested). Known gap: a parked (off-display) window may not capture,
      leaving the old thumbnail under the caption (`peek capture failed` in the log).
  - **Open questions:** filter vs dim the grid; type-to-search directly in Overview; empty query as a
    recent-windows switcher; panel size vs the card grid on a 1440 px display.
  - **Next phases (after feedback):** (a) verify Safari / Chromium / native tabs and add per-app
    tab-group rules where `pickTabGroup` is ambiguous (log line `AMBIGUOUS`); (b) MRU ranking boost
    (needs a focus-history in `StripController`); (c) non-AX providers — `wezterm cli`, AppleScript
    URLs for Safari/Chrome (Automation TCC prompt per app), windows outside the ring (minimized /
    hidden / other display; selecting one adopts or un-minimizes it); other Spaces stay deferred.
- ~~**Swap focused ↔ neighbor** (S)~~ — ✅ shipped 2026-07-01: `StripState.moveFocused(_:)` (pure,
  tested) swaps the focused slot's window with its immediate slot-neighbor (L↔C or C↔R), guaranteed
  to land exactly there — a clean two-window exchange, everything else undisturbed. Focus rides along
  with the carried window. No-op on a pinned focused slot; pinned slots are skipped over (never moved)
  when looking for the neighbor to swap with. `StripController.moveFocused` wraps it; ⌃⌥⇧H/L
  (`AppDelegate` `.movePrev`/`.moveNext`) call it.
  - Because the anchor slot always *displays* `centerId` by identity, not by ring position (see
    `resolve()`), a swap into/out of the anchor hands `centerId` to whichever window moves there —
    otherwise the swap wouldn't actually relocate what's shown in that slot.
  - This replaced (and improves on) the pre-existing ⌃⌥⇧H/L implementation, whose old ring-index
    swap only worked correctly when the focused window *was* the centered one, and even then could
    cascade and shift a slot two positions away rather than swapping with its literal neighbor — an
    adversarial review caught this by comparing live `/tmp/strip.log` output against the literal
    "swap to the center/right neighbor" wording in this backlog entry and `IDEAS.md`.

## Deferred (revisit only if the setup changes)

- **Multi-display** — per-display strips, window-follows-active-display. Parked because: single ultrawide.
- **macOS Spaces + fullscreen apps** — windows on other Spaces aren't AX-enumerable without focusing
  them; large effort, low value for the current single-Space-per-display workflow.

## Open bugs

See `BUGS.md`. Current: (1) quit→reopen rearranges window order (should preserve, like Re-tile);
(2) stale overlay (focus ring + rail chips) when the last managed window exits.
(Fixed 2026-06-30: minimize/hide-on-close gap — reconcile now drops windows the window server no
longer shows on screen, so the strip closes up.)

## Prototype reference & feel notes (for M4/M5)

The prototype is the **visual spec** — re-read it when building chrome:
The original design export is intentionally excluded from this repository. Durable behavior is
specified by the Swift layout engine, tests, architecture documentation, and accepted ADRs.

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

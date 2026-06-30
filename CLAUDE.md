# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Strip** — a real macOS window manager (spike) implementing a niri-style "film-strip" tiling
concept: windows live on a horizontal film, the focused window stays centered, neighbors flow past
it. It is **Swift + AppKit, Accessibility-API only, no SIP, no scripting addition**.

**`PLAN.md` is the authoritative project doc** — the source of truth for roadmap, milestone progress
(M0–M7 done & user-confirmed; M8 workspaces is next), architecture rationale, the verified-seam map,
and the do-not-relearn gotchas. **`HANDOFF.md` is the active-task brief** — a per-task handoff for an
agent, replaced wholesale each time a new task starts (not a roadmap). Read both before substantive
work. Engram has deeper context: `mem_search "strip-wm-spike"`.

The `wm-prototype/` directory is the **design spec** (an exported HTML/CSS/JS mockup), not code to
port. Its `geom()`/`resolve()`/`computeVM()` logic was ported into the Swift layout engine; its
visuals guide the (not-yet-built) overlay chrome. PLAN.md indexes the relevant prototype line ranges.

## Commands

```
make test            # swift test — pure engine tests, no permissions needed
make bundle          # build + assemble + sign .build/Strip.app
make open            # bundle + launch via LaunchServices (the only TRUSTED run; see below)
make run             # bundle + run inner binary — build-check only, NOT trusted
make setup-signing   # one-time: create the stable "Strip Dev" code-signing identity
```
Single test: `swift test --filter StripLayoutTests/testRingWrapsAround` (or a whole suite:
`swift test --filter StripLayoutTests`).

## Running it (critical, non-obvious)

- **Accessibility trust requires a LaunchServices launch.** Running the binary from a shell is NOT
  granted Accessibility (TCC attributes it to the parent shell), so always run with **`make open`**.
- Because `open`-launched agents have **no stdout**, the app logs to **`/tmp/strip.log`** — `cat`/
  `tail` that to observe behavior (window placements, hotkeys, errors).
- **Signing must stay stable** or every rebuild invalidates the grant. The "Strip Dev" self-signed
  cert handles this. If you change the signing identity, the grant resets — run
  `tccutil reset Accessibility com.spike.strip`, `make open`, and re-toggle Strip in System Settings
  → Privacy & Security → Accessibility. (The cert reports `CSSMERR_TP_NOT_TRUSTED` and is hidden by
  `security find-identity -v`; detect it without `-v`. codesign + TCC accept it regardless.)

## Performance work — MEASURE FIRST (enforced)

**No performance change lands without a measurement that justifies it.** This is a hard rule, not a
preference. `MEASURING.md` is the authoritative how-to (signposts, xctrace, DuckDB queries, synthetic
chord workloads, A/B via `git stash`, fps/freeze/backpressure metrics, screencapture verification) —
read it before any perf work.

1. **Baseline before touching code.** Capture a trace of the actual hot path with a controlled,
   repeatable workload and read the p50/p90/**max** (the tail is the bug). If the thing isn't
   measurable, the *first* change is instrumentation (an `os_signpost` interval/event), not a fix.
2. **No speculative optimization.** Don't "fix" what you haven't measured. The original review inflated
   impact by reasoning about 50–100 windows; the real working set is `cols` (default 3). Layout
   (`placements` p50 0.07ms) was never a bottleneck — measurement said so.
3. **A/B every change.** Same window set, same workload, before vs after. Prefer a true before/after
   via `git stash` (see `MEASURING.md`) over trusting a remembered/estimated baseline. Pick the
   workload that actually exercises the change (a continuous-motion storm and a settle-based reseed can
   give opposite verdicts).
4. **Commit with the numbers.** Every perf commit body states the measured before→after **and the
   exact workload**. Update the `perf-review-2026-06` memory note with the verdict.
5. **Verify visual changes with eyes**, not just metrics — `screencapture` + inspect, captured *across*
   a state change so a stale render can't pass (needs Screen Recording permission).
6. **Respect proven dead ends — don't re-fight them.** Two hard platform limits, each cost a
   measured, reverted attempt:
   - **`kAXWindows` enumeration is main-thread-only** (off-main returns degraded data). Per-element AX
     reads/writes on an already-obtained window element *do* work off-main on a per-pid serial queue.
     The lever for enumeration cost is **frequency** (don't enumerate on pure focus/activation), not
     threading. See `mem_search "ax-enumeration-main-bound"`.
   - **SwiftUI/AppKit view rendering is main-thread-only** — it can't move off-thread. Make it cheap
     (incremental `@Published` updates, no forced `layoutSubtreeIfNeeded`/rootView rebuild), don't try
     to relocate it.
7. **Keep `make test` green** through perf work and **extract pure logic** so new decisions stay
   headless-testable even when the surrounding code is AppKit/SwiftUI.

## Architecture (the big picture)

Strip is a window manager for macOS. It runs as a background accessory app (`LSUIElement`,
`.accessory`) — no Dock icon, no main window — so it never takes focus from the windows it manages;
the menu bar status item is just one of its surfaces. The command flow is:

```
HotkeyService (⌃⌥ CGEventTap)  ─┐
status-bar menu                ─┴─▶ StripController ──▶ StripLayout (pure) ──▶ WindowAnimator ──▶ AX writes
                                        │  mutates StripState           placements[]      springs frames
                                        └─ AccessibilityService: enumerate/track real windows
```

- **`StripLayout` + `SlotGeometry` + `StripState` (`Layout/`, `Model/`) are pure** — no AppKit side
  effects, fully unit-tested. This is the faithful port of the prototype's `geom()`/`resolve()`/
  `computeVM()`. `resolve()` does pin-aware ring rotation (which window lands in which slot);
  `placements(in:)` projects slot geometry onto the display's visible frame and pushes off-strip
  windows fully off the edge ("parked"). All layout/feature logic should go here so it stays testable.
- **`StripController`** is the only stateful coordinator: it owns `StripState` and the managed-window
  set, reconciles enumeration on `refresh()`, and on every command recomputes placements and hands
  them to the animator. Window membership is sticky — a window stays managed while it *exists* (even
  parked off-screen); the on-display test only gates *new* windows, and orphaned off-screen windows
  are reclaimed on `refresh()`.
- **`WindowAnimator` (`Animation/`)** is the only thing that moves real windows. Smooth motion with
  no SIP = `NSScreen.displayLink` loop → per-window `RectSpring` → write `kAXPosition`/`kAXSize`
  every frame **off the main thread on a per-app serial queue**, with `AXEnhancedUserInterface`
  disabled on each app for the motion's duration, and the "set size twice" idiom in `AXWindow.setFrame`
  to defeat constraint clamping. This is the proven rift/OmniWM technique.
- **Coordinates:** everything internal is **Quartz global** (top-left origin, Y down — what the AX
  API uses). Convert to Cocoa (bottom-left) only at the AppKit boundary, via `Coordinates.swift` /
  `NSScreen.quartz*Frame`.
- **Window identity** is `CGWindowID` via `_AXUIElementGetWindow` (a private but no-SIP symbol;
  `PrivateAPIs.swift`), used only for identity — never to move windows.

## Constraints to respect

- Real app windows can only be **moved/resized** via AX — no 3D, no per-window opacity. The
  prototype's carousel/pop/fade are not reproducible on live windows; the `t` key cycles **spring
  presets** instead. Parked windows slide off-screen rather than fade.
- **Terminal apps step during resize** (they quantize to character cells) — inherent to AX, not a
  bug. Most apps resize per-pixel and are smooth.
- Keep the package at **Swift language mode v5** (set in `Package.swift`) — it avoids Swift 6
  Sendable friction with CoreFoundation/AX types.

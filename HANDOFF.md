# HANDOFF — start here (next: M3, pinning)

You're resuming the **Strip** macOS window-manager spike. M0–M2 are done and user-confirmed. This
doc gets you productive on **M3** fast. Read **PLAN.md** for the full picture; this is the focused
next-step guide.

## 1. Orient (5 min)

- Skim **PLAN.md** (goal, decisions, architecture, milestone progress, gotchas).
- Recall prior context: `mem_search "strip-wm-spike"` (engram has the detailed session memory).
- Confirm the toolchain still works:
  ```
  make test          # 15 tests should pass (pure engine)
  make open          # tiles your real windows; logs to /tmp/strip.log
  cat /tmp/strip.log
  ```
  `make open` (LaunchServices) is the only TRUSTED way to run — the raw binary from a shell isn't
  granted Accessibility. Logs go to `/tmp/strip.log` because open-launched apps have no stdout.
- The "Strip Dev" signing identity already exists on this machine, so the Accessibility grant
  persists across rebuilds. If trust ever breaks: `tccutil reset Accessibility com.spike.strip`
  then `make open` and re-toggle Strip in System Settings → Privacy → Accessibility.

## 2. Current state

Working: window enumeration, the pure layout engine (monocle/2-up/3-up, focus/equal emphasis,
ring rotation, pin-aware assignment — pins already work in the *engine*), smooth display-link
spring animation of real windows, and the ⌃⌥ hotkey tap (slide, focus, reorder, cols, emphasis,
spring-cycle). The **pin engine logic exists and is tested**; what's missing is the **command to
toggle a pin** and binding it to ⌃⌥P.

## 3. M3 task — pinning (small, mostly wiring)

**Goal:** ⌃⌥P pins/unpins the focused slot; pinned windows stay put while others flow. The layout
engine already honors `state.pins` (see `StripLayout.resolve()` and `StripLayoutTests`), so this is
a controller command + hotkey binding.

### Step 1 — port `togglePin` into `StripController`

Add a `togglePin()` method. Faithful port of the prototype (`wm-prototype/macos-window-manager-
prototype/project/Strip Window Manager.dc.html`, lines 355-374):

```js
togglePin() {
  const fs = this.state.focusSlot;
  const pins = { ...this.state.pins };
  if (pins[fs]) { delete pins[fs]; /* unpin */ return; }
  const R = this.resolve();
  const id = R.assign[fs];          // window currently in the focused slot
  if (!id) return;
  pins[fs] = id;                    // pin it
  const slots = slotKeysFor(cols);
  const up = slots.filter(s => !pins[s]);
  const prim = primaryFor(cols);
  let focusSlot = up.includes(prim) ? prim : (up[0] || fs);
  let centerId = this.state.centerId;
  const pinnedSet = new Set(Object.values(pins));
  if (pinnedSet.has(centerId)) {                       // if center got pinned,
    centerId = ring.filter(x => !pinnedSet.has(x))[0]  // move center to first unpinned
               || centerId;
  }
  // setState: pins, focusSlot, centerId
}
```

Swift sketch (mirror existing methods in `StripController.swift`; call `apply()` at the end):
```swift
public func togglePin() {
    let fs = state.focusSlot
    if state.pins[fs] != nil { state.pins[fs] = nil; normalize(); apply(); return }
    let assign = StripLayout(state).assignment()
    guard let id = assign[fs] else { return }
    state.pins[fs] = id
    let up = state.slots.filter { state.pins[$0] == nil }
    state.focusSlot = up.contains(state.primarySlot) ? state.primarySlot : (up.first ?? fs)
    let pinned = Set(state.pins.values)
    if let c = state.centerId, pinned.contains(c) {
        state.centerId = state.ring.first { !pinned.contains($0) } ?? c
    }
    normalize()
    apply()
}
```
(`assignment()` already exists on `StripLayout`. `normalize()` already clamps pins/focus to valid
slots.)

### Step 2 — bind the hotkey

In `AppDelegate.handle(_:)`, the `.togglePin` case currently logs "coming in a later milestone".
Change it to `controller.togglePin()`. (`HotkeyCommand.togglePin` is already emitted for ⌃⌥P by
`HotkeyService`.)

### Step 3 — feedback (lightweight, until the M4 rail)

There's no visual pin badge yet (that arrives with the film rail in M4). For now, `apply()` already
logs slot assignments — add the pinned slot(s) to that log line so you can verify in
`/tmp/strip.log`. Optionally add a "Pin focused slot" item to the status menu for mouse testing.

### Step 4 — tests

Add `StripControllerTests`-style coverage at the engine level (the controller mutates `StripState`,
which is pure): pin C → C holds its window while ⌃⌥H/L flow others; unpin restores flow; pinning the
centered window moves center to the first unpinned. (Engine pin behavior is already covered in
`StripLayoutTests`; new tests should assert the *togglePin state transition* — easiest by factoring
the pin logic so it can run on a bare `StripState`, or by testing `assignment()` before/after.)

### Verify M3
`make test` green; `make open`; open ≥4 windows; ⌃⌥P on a slot, then ⌃⌥H/L — pinned window stays
put while others slide through; ⌃⌥P again unpins. Check `/tmp/strip.log`.

### When done
Update **PLAN.md** progress (check off M3), update engram (`mem_save`, topic `strip-wm-spike`), and
proceed to **M4 (overlay chrome)** — the first milestone that makes Strip *look* like the prototype:
SwiftUI borderless NSWindows for the film rail (with pin badges), focus ring, status pill, and the
Help overlay (⌃⌥/). See PLAN.md "Architecture / file map" for where overlay files should live
(`Sources/StripKit/Overlay/`).

## 4. Don't relearn these (full list in PLAN.md "gotchas")

- Trust needs LaunchServices (`make open`); observe via `/tmp/strip.log`.
- Keep signing identity stable (already set up) or you'll re-grant every build.
- Internal coords are Quartz (top-left); convert to Cocoa only for AppKit overlays.
- Terminal apps step during resize (character-cell quantization) — inherent, not a bug.

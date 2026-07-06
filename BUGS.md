# Bugs

## Triage

- Quit and reopen rearranges the order of windows.
  Ideally, the order of windows should be preserved similar to Re-tile.

- When the last managed window exits, Strip's overlay chrome goes stale instead of clearing:
  the focus ring stays drawn over empty wallpaper (at the dead window's last frame) and the
  film rail keeps showing chips for windows that no longer exist. Observed 2026-07-02
  (screenshot: 0 real windows, ring on bare wallpaper at the left screen edge, rail still
  showing 3 chips).
  Root cause: `StripController.apply()` guards `!state.ring.isEmpty` and returns before doing
  anything. `refresh()` correctly empties the ring when the last window closes, but the
  subsequent `apply()` bails out, so (a) `onRender?(railSnapshot(...))` never publishes an
  empty snapshot — the rail keeps its last non-empty render — and (b) the animator is never
  re-targeted, `animator.focusedID` stays pointing at the dead window and no
  `onFocusFrame(nil)` is ever emitted, so `OverlayController.updateFocusRing` never gets the
  `nil` that would `orderOut` the ring panel.
  Likely fix shape: on empty ring, `apply()` should still clear the presentation — emit an
  empty rail snapshot, clear `animator.focusedID`, and emit `onFocusFrame(nil)` (or hide the
  overlay entirely) — before skipping the placement/animation work.

## Fixed

- macOS native apps' real window size disagrees with Strip's layout: Console, Music, Photos
  end up *wider* than their slot (their AppKit `contentMinSize` — e.g. Console 600px — exceeds
  the commanded slot width, so the resize silently clamps and the window spills under its
  neighbor), while System Settings ends up *smaller* (its window is effectively fixed-size,
  so it never grows to fill the slot). Observed 2026-07-02 (screenshot: Console's real window
  extends past the focus ring and overlaps the next slot; ring drawn at the commanded frame).
  Fixed 2026-07-02 by closing the loop the "min-size clamp" fix below deliberately left open —
  layout now *learns* each window's real size bounds from clamp events and sizes slots around
  them:
  - `SizeConstraint` (Model/): per-window, per-dimension learned floor/ceiling. A settle
    read-back that comes back larger than requested raises the floor (Console); smaller lowers
    the ceiling (Settings — "fixed-size" emerges as floor ≈ ceiling). Monotone (floors only
    rise, ceilings only fall), thresholded (≥8px, so terminal cell-quantization noise teaches
    nothing), floors capped at the screen — which is why re-applying is now safe: the loop
    terminates, no infinite clamp cycle. NOTE: detecting fixed windows upfront via
    `AXWindow.isResizable == false` was verified to be a dead end — such windows are classified
    `.floating` and never managed, and Settings reports its size *settable* and clamps anyway.
  - `SlotGeometry.rects`/`solveWidths` take per-slot requirements: a slot below its window's
    floor is raised, one above its ceiling shrunk, the difference redistributed proportionally
    among slots still free to move; heights clamp per-slot (re-centered). Floors that can't fit
    are emitted verbatim — the centered row spills off the display edges (honest last resort,
    logged `constraint-unsatisfiable`; auto-dropping `cols` is a deferred backlog decision).
  - `StripController.reconcileClampedFrame` learns (`constraint-learned:` log line) and
    re-applies once per genuinely-new bound; `WindowAnimator.acceptReality` adopts the achieved
    frame as the entry's target/spring/lastWritten so the next tick doesn't re-fight the app and
    **the focus ring hugs the real window frame**, even when unsatisfiable.
  Covered by `SizeConstraintTests` + `StripLayoutTests` constraint cases (pure), and
  `scenario_constraint_learning` / `_assert_real_frame`'s upgraded contract (e2e): after a
  `constraint-learned` line the real frame must *converge* to the re-apply's commanded frame,
  and repeating the layout must learn nothing new.

- Strip doesn't detect when a commanded window frame is silently clamped by the target app's own
  minimum window size, so its internal model (and log) can permanently disagree with the real screen.
  Found 2026-07-02 via `scenario_layout_switch`'s new real-world AX check (`make e2e-vm`,
  TESTING.md §3 "Trusting the log vs. trusting reality"): in 3-up, the non-focused "peek" slots are
  narrow (142px on a small VM display) — narrower than Activity Monitor's (740px) or Console's
  (600px) true minimum content width. Confirmed independently of Strip (a bare `System Events` resize
  to 142px on Activity Monitor silently clamps to 740px): this is the app's own AppKit
  `contentMinSize`, a harder constraint than the OS-level resize clamping `AXWindow.setFrame`'s
  "set size twice" idiom defeats — no AX retry can beat it.
  Fixed 2026-07-02 ("reconcile only" scope, not layout-side avoidance): once a window's spring
  settles, `WindowAnimator` reads back the real AX frame once (`AXWindow.frame`, off-main on the
  existing per-pid queue) and fires `onFrameClamped` if it doesn't match the commanded frame.
  `StripController.reconcileClampedFrame` updates the cached `ManagedWindow.frame` to reality and
  logs a `frame-clamped: <app> requested=(...) actual=(...)` line — deliberately does not re-`apply()`,
  since `SlotGeometry` still has no minimum-size awareness and would just recompute the same
  impossible target (that's a separate, larger follow-up: teaching layout to account for a window's
  learned minimum when sizing slots, not done here). `scenario_layout_switch`'s real-frame check was
  updated to match this contract (detect + honestly record drift, not "drift never happens") and is
  green under `make e2e-vm`.

- Windows that minimize to the taskbar when closed leaves a gap in the layout.
  The layout should adjust to fill the space left by minimized windows. Example: Slack.
  Fixed 2026-06-30: reconcile now treats a ring window as live only when the window server
  shows it *on screen* (`onScreenWindowIDs`, `.optionOnScreenOnly`), and `allWindows()` skips
  hidden apps (`!app.isHidden`) — so minimized, hidden (⌘H), and closed-to-Dock windows drop
  out and the strip closes the gap, while Strip's own parked windows are unaffected.

- When a window is pinned to a slot, the focus ring disappears and the pinned slot is skipped
  when navigating with J and K keys. Additionally, pinning a window to a slot causes the focus
  to shift to the left slot instead of remaining on the pinned slot.
  Fixed 2026-06-28 (`03001b0`): focus ring is allowed on pinned windows during navigation.

- Focus ring aka border is shown with the highest z-index, it's rendered even on macOS
  notifications, which is not ideal.
  Fixed 2026-06-28 (`94c3f55`): the focus-ring panel was lowered from `.statusBar` to
  `.floating` so notification banners draw above it.

- When a new window is opened which by default has small size (for example: the dmg installer
  window), all other windows are resized to fit the new window, which is not ideal.
  Fixed 2026-06-28 (`94c3f55`): intrinsically-small new windows are left floating instead of
  tiled (`isTileableSize` gates new-window admission).

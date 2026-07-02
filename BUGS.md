# Bugs

## Triage

- Quit and reopen rearranges the order of windows.
  Ideally, the order of windows should be preserved similar to Re-tile.

- Strip doesn't detect when a commanded window frame is silently clamped by the target app's own
  minimum window size, so its internal model (and log) can permanently disagree with the real screen.
  Found 2026-07-02 via `scenario_layout_switch`'s new real-world AX check (`make e2e-vm`,
  TESTING.md §3 "Trusting the log vs. trusting reality"): in 3-up, the non-focused "peek" slots are
  narrow (142px on a small VM display) — narrower than Activity Monitor's (740px) or Console's
  (600px) true minimum content width. Confirmed independently of Strip (a bare `System Events` resize
  to 142px on Activity Monitor silently clamps to 740px): this is the app's own AppKit
  `contentMinSize`, a harder constraint than the OS-level resize clamping `AXWindow.setFrame`'s
  "set size twice" idiom defeats — no AX retry can beat it. Strip should either detect the achieved
  size differs from the requested one and reconcile its model to match, or account for a window's
  known minimum size when computing slot widths. Left as a known-red assertion in the e2e suite
  rather than loosened, since it's a real gap, not a test bug.

## Fixed

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

# Bugs

## Triage

- Quit and reopen rearranges the order of windows.
  Ideally, the order of windows should be preserved similar to Re-tile.

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

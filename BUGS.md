- Quit and reopen rearranges the order of windows.
  Ideally, the order of windows should be preserved similar to Re-tile.
- When a window is pinned to a slot, the focus ring disappears and the pinned slot is skipped when navigating with J and K keys.
  Additionally, pinning a window to a slot causes the focus to shift to the left slot instead of remaining on the pinned slot.
- Focus ring aka border is shown with the highest z-index, it's rendered even on macos notifications, which is not ideal.
- When a new window is opened which by default has small size (for example: the dmg installer window), all other windows are resized to fit the new window, which is not ideal.

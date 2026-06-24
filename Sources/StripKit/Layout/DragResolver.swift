import CoreGraphics

/// Pure inversion of `SlotGeometry` for *respect-user-drags* (M7 Slice 4): when the user resizes the
/// dominant (emphasized) window by hand, map its new frame back into the layout's sizing knobs so the
/// whole strip re-proportions to honor the drag instead of snapping the window back.
///
/// Kept pure (`CGRect` math only, no AppKit/AX) so the "which knob does this resize map to, and to
/// what value" logic is unit-tested directly — `StripController` just decides *whether* a given
/// dragged window is the dominant one and feeds its live frame in here.
enum DragResolver {
    /// Invert the emphasized slot's geometry: produce the `LayoutConfig` that would place the
    /// dominant window at `frame` within `vis`.
    ///
    /// - Height maps to `heightFraction` (it governs **every** slot, so any kept resize re-heights
    ///   the whole strip uniformly — the existing ⌃⌥taller/shorter behavior).
    /// - Width maps to the dominant window's width knob: `monocleWidthFraction` in monocle (1-up),
    ///   `focusRatio` in `focus` emphasis with more than one column. In `equal` emphasis there is no
    ///   width knob (every column is `windowArea/n`), so width is left untouched and snaps back on
    ///   re-apply.
    ///
    /// All values are clamped to `LayoutConfig`'s ranges. This is the exact inverse of
    /// `SlotGeometry.rects(...)` for the emphasized slot, so feeding a slot rect straight back here
    /// round-trips to (approximately) the same config.
    static func resizeConfig(focusFrame frame: CGRect, vis: CGRect, cols: Int,
                             emphasis: Emphasis, base: LayoutConfig) -> LayoutConfig {
        var cfg = base
        let pad = max(0, base.outerPadding)

        // Height: inverse of `clampedHeight * usableH`.
        let usableH = max(1, vis.height - 2 * pad)
        cfg.heightFraction = frame.height / usableH
        cfg.heightFraction = cfg.clampedHeight

        // Width: inverse depends on the layout the dominant window lives in.
        let usableW = max(1, vis.width - 2 * pad)
        if cols == 1 {
            // Monocle: inverse of `clampedMonocleWidth * usableW`.
            cfg.monocleWidthFraction = frame.width / usableW
            cfg.monocleWidthFraction = cfg.clampedMonocleWidth
        } else if emphasis == .focus {
            // Focus emphasis: inverse of `clampedFocusRatio * windowArea`, where
            // `windowArea = usableW - (n-1)*gap` (matches `SlotGeometry`).
            let n = cols == 2 ? 2 : 3
            let gap = max(0, base.innerGap)
            let windowArea = max(1, usableW - CGFloat(n - 1) * gap)
            cfg.focusRatio = frame.width / windowArea
            cfg.focusRatio = cfg.clampedFocusRatio
        }
        // `equal` emphasis: width is fixed at windowArea/n — no knob to honor, width snaps back.

        return cfg
    }
}

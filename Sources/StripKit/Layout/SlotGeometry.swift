import CoreGraphics

/// Computes the concrete slot rectangles for a layout, driven by a `LayoutConfig`.
///
/// This replaces the prototype's fixed 1440×900 "stage" boxes (which were tuned for a demo aesthetic
/// and left big wallpaper margins on a real ultrawide). Windows now **fill the full usable height**
/// and **span the usable width edge-to-edge** — with configurable outer padding and inter-window
/// gaps — and `focus` emphasis distributes width by `config.focusRatio`. Output is in Quartz
/// coordinates (top-left origin, Y down — what the AX API uses).
enum SlotGeometry {
    /// Ordered, on-screen slot rects for `cols`/`emphasis`/`focusSlot` within the visible frame `vis`.
    static func rects(cols: Int, emphasis: Emphasis, focusSlot: Slot, in vis: CGRect,
                      config: LayoutConfig) -> [Slot: CGRect] {
        let pad = max(0, config.outerPadding)
        let gap = max(0, config.innerGap)
        let usableH = max(0, vis.height - 2 * pad)
        // Height fraction shrinks every window vertically, centered within the usable height.
        let height = config.clampedHeight * usableH
        let top = vis.minY + pad + (usableH - height) / 2
        let usableW = max(0, vis.width - 2 * pad)

        // Monocle: a single window centered with margins on both sides (full-width is too wide to use
        // on an ultrawide). `monocleWidthFraction` controls how much it fills, up to 1.0 ("filled").
        if cols == 1 {
            let w = config.clampedMonocleWidth * usableW
            return [.C: CGRect(x: vis.midX - w / 2, y: top, width: w, height: height)]
        }

        let slots: [Slot]
        switch cols {
        case 2:  slots = [.L, .R]
        default: slots = [.L, .C, .R]
        }
        let n = slots.count
        // Width available for the windows themselves, once the inter-window gaps are removed.
        let windowArea = max(0, usableW - CGFloat(n - 1) * gap)

        // The emphasized (wide) slot: in 2-up it's the focused slot; otherwise the center anchor.
        let rawEmphasis: Slot = (cols == 2) ? focusSlot : .C
        let emphasized = slots.contains(rawEmphasis) ? rawEmphasis : (slots.first ?? .C)

        var widths: [Slot: CGFloat] = [:]
        if emphasis == .focus && n > 1 {
            let fr = config.clampedFocusRatio
            let focusW = fr * windowArea
            let sideW = (1 - fr) * windowArea / CGFloat(n - 1)
            for s in slots { widths[s] = (s == emphasized ? focusW : sideW) }
        } else {
            for s in slots { widths[s] = windowArea / CGFloat(n) }
        }

        // Lay the slots out left-to-right with gaps between them.
        var rects: [Slot: CGRect] = [:]
        var x = vis.minX + pad
        for s in slots {
            let w = widths[s] ?? windowArea / CGFloat(n)
            rects[s] = CGRect(x: x, y: top, width: w, height: height)
            x += w + gap
        }
        return rects
    }

    /// Vertical center line of the strip within `vis` (used to vertically center parked windows).
    /// With full-height windows the strip is simply centered in the visible frame.
    static func centerY(in vis: CGRect) -> CGFloat { vis.midY }
}

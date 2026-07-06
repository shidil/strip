import CoreGraphics

/// Computes the concrete slot rectangles for a layout, driven by a `LayoutConfig`.
///
/// This replaces the prototype's fixed 1440×900 "stage" boxes (which were tuned for a demo aesthetic
/// and left big wallpaper margins on a real ultrawide). Windows now **fill the full usable height**
/// and **span the usable width edge-to-edge** — with configurable outer padding and inter-window
/// gaps — and `focus` emphasis distributes width by `config.focusRatio`. Output is in Quartz
/// coordinates (top-left origin, Y down — what the AX API uses).
///
/// Slots can carry per-window `SizeConstraint` requirements (learned from clamp events — see
/// `SizeConstraint`): a slot below its window's floor is raised to it, one above its ceiling is
/// shrunk to it, and the difference is redistributed among the slots still free to move. When the
/// floors alone exceed the usable width the floors are emitted anyway — commanded = achievable, so
/// overlap becomes an honest last resort instead of a silent clamp the layout doesn't know about.
enum SlotGeometry {
    /// Ordered, on-screen slot rects for `cols`/`emphasis`/`focusSlot` within the visible frame `vis`.
    static func rects(cols: Int, emphasis: Emphasis, focusSlot: Slot, in vis: CGRect,
                      config: LayoutConfig,
                      requirements: [Slot: SizeConstraint] = [:]) -> [Slot: CGRect] {
        let pad = max(0, config.outerPadding)
        let gap = max(0, config.innerGap)
        let usableH = max(0, vis.height - 2 * pad)
        // Height fraction shrinks every window vertically, centered within the usable height.
        let height = config.clampedHeight * usableH
        let usableW = max(0, vis.width - 2 * pad)
        // Heights are independent per slot (no packing): clamp each to its window's learned bounds
        // and re-center vertically, so a ceiling-height window gets a slot it can actually fill.
        func yAndHeight(_ s: Slot) -> (y: CGFloat, h: CGFloat) {
            let h = requirements[s]?.clampedHeight(height) ?? height
            return (vis.minY + pad + (usableH - h) / 2, h)
        }

        // Monocle: a single window centered with margins on both sides (full-width is too wide to use
        // on an ultrawide). `monocleWidthFraction` controls how much it fills, up to 1.0 ("filled").
        if cols == 1 {
            var w = config.clampedMonocleWidth * usableW
            w = requirements[.C]?.clampedWidth(w) ?? w
            let (y, h) = yAndHeight(.C)
            return [.C: CGRect(x: vis.midX - w / 2, y: y, width: w, height: h)]
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
        widths = solveWidths(ideal: widths, order: slots, requirements: requirements,
                             windowArea: windowArea)

        // Lay the slots out left-to-right with gaps between them. The row is centered within the
        // usable width: with no constraints the solved widths sum to `windowArea` exactly, so this
        // is today's `vis.minX + pad` start; an under-filled row (every window at its ceiling) gets
        // symmetric margins, and an over-full one (floors exceed the area) spills evenly off both
        // sides instead of shoving the whole overflow under the right neighbor.
        var rects: [Slot: CGRect] = [:]
        let occupied = slots.reduce(0) { $0 + (widths[$1] ?? 0) } + CGFloat(n - 1) * gap
        var x = vis.minX + pad + (usableW - occupied) / 2
        for s in slots {
            let w = widths[s] ?? windowArea / CGFloat(n)
            let (y, h) = yAndHeight(s)
            rects[s] = CGRect(x: x, y: y, width: w, height: h)
            x += w + gap
        }
        return rects
    }

    /// Constraint-aware width solve: clamp each slot to its window's learned bounds and
    /// redistribute the difference proportionally among the slots still free to move in the needed
    /// direction (a slot pinned at its floor can still grow; one at its ceiling can still shrink).
    /// Iterates because redistribution can push a previously-free slot into its own bound — with
    /// n ≤ 3 this settles within `n` rounds. When no slot can move (floors overflow the area, or
    /// ceilings under-fill it) the bounds are emitted as-is — the honest last resort.
    static func solveWidths(ideal: [Slot: CGFloat], order: [Slot],
                            requirements: [Slot: SizeConstraint],
                            windowArea: CGFloat) -> [Slot: CGFloat] {
        guard !requirements.isEmpty else { return ideal }
        var widths = ideal
        for _ in 0...order.count {
            for s in order {
                if let r = requirements[s], let w = widths[s] { widths[s] = r.clampedWidth(w) }
            }
            let total = order.reduce(0) { $0 + (widths[$1] ?? 0) }
            let diff = windowArea - total
            if abs(diff) < 0.5 { break }
            // Slots able to absorb the difference: growing is blocked by a ceiling, shrinking by a
            // floor (0.5px slack so a slot sitting exactly on its bound counts as pinned).
            let free = order.filter { s in
                guard let r = requirements[s], let w = widths[s] else { return true }
                return diff > 0 ? w < (r.maxWidth ?? .greatestFiniteMagnitude) - 0.5
                                : w > (r.minWidth ?? 0) + 0.5
            }
            let freeTotal = free.reduce(0) { $0 + (widths[$1] ?? 0) }
            guard !free.isEmpty, freeTotal > 0 else { break }
            // `max(0, …)`: two floors can exceed the whole area, asking the free slot to absorb more
            // deficit than it has — floor it at zero and let the overflow stand (honest overlap).
            for s in free { widths[s] = max(0, (widths[s] ?? 0) * (1 + diff / freeTotal)) }
        }
        // Bounds are never violated, even when unsatisfiable — the floor is what the app will
        // actually do, so commanding it keeps the layout's account of the world truthful.
        for s in order {
            if let r = requirements[s], let w = widths[s] { widths[s] = r.clampedWidth(w) }
        }
        return widths
    }

    /// Vertical center line of the strip within `vis` (used to vertically center parked windows).
    /// With full-height windows the strip is simply centered in the visible frame.
    static func centerY(in vis: CGRect) -> CGFloat { vis.midY }
}

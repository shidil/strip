import CoreGraphics

extension StripState {
    /// Seats & Pile migration (`docs/design/seats-and-pile.md`, *Migration*): the `Table` that shows
    /// exactly what today's ring shows. Each window `resolve()` puts in a slot takes that seat, pins
    /// become seat locks, focus stays on its slot, and the pile is `pile` — recency first, then ring
    /// distance from the center (right before left). From then on real recency takes over.
    ///
    /// Seats come from `placements(in:)` rather than `resolve().assign`: with fewer windows than
    /// slots the ring's assignment repeats a window, while placements give each window one slot.
    /// Which slot a window gets doesn't depend on the display, so any frame works.
    public var table: Table {
        let layout = StripLayout(self)
        var seats: [Slot: CGWindowID] = [:]
        for p in layout.placements(in: CGRect(x: 0, y: 0, width: 1440, height: 900)) {
            if let s = p.slot { seats[s] = p.id }
        }
        let seated = Set(seats.values)
        var t = Table(seats: seats,
                      pile: pile.filter { !seated.contains($0) },
                      locks: Set(pins.filter { seats[$0.key] == $0.value }.keys),
                      focusSeat: layout.resolve().focusSlot,
                      lastTrade: lastTrade,
                      cols: cols, emphasis: emphasis, config: config)
        t.normalize()
        return t
    }
}

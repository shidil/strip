import CoreGraphics

/// A fixed on-screen position in the strip. The film of windows flows *through* these slots; the
/// slots themselves never move (the core idea: "the center slot never moves").
public enum Slot: String, CaseIterable, Hashable {
    case L, C, R
}

/// Column emphasis: `focus` makes the primary column dominate; `equal` gives columns equal width.
public enum Emphasis: Hashable {
    case focus, equal
}

/// The seat keys U / I / O: they name the left / center / right seat in every picker and chord
/// (Seats & Pile, *Picking a target seat*). `StripState.seat(for:)` maps a key to the slot it means
/// for the current column count.
public enum SeatKey: String, CaseIterable, Hashable {
    case u, i, o
}

/// Two windows that traded seats: `a` moved from `from` to `to`, and `b` moved from `to` to `from`.
public struct Trade: Equatable {
    public let a: CGWindowID
    public let b: CGWindowID
    public let from: Slot
    public let to: Slot
}

/// A draw: `drawn` came off the pile into `seat`, and `displaced` went to the top of the pile.
public struct Draw: Equatable {
    public let drawn: CGWindowID
    public let displaced: CGWindowID
    public let seat: Slot
}

/// The complete logical state of the strip — the direct analogue of the prototype's `state` object
/// (`Strip Window Manager.dc.html`, lines 117-129). Windows are identified by `CGWindowID`.
public struct StripState {
    /// The film: the ordered ring of managed window ids.
    public var ring: [CGWindowID]
    /// The window currently brought to the anchor (center) slot.
    public var centerId: CGWindowID?
    /// Column count: 1 (monocle), 2, or 3.
    public var cols: Int
    public var emphasis: Emphasis
    /// Slot → window id for pinned slots; pinned windows stay put while others flow.
    public var pins: [Slot: CGWindowID]
    /// The slot that currently has keyboard focus.
    public var focusSlot: Slot
    /// Tunable window-sizing knobs (padding, gaps, focus width ratio) — see `LayoutConfig`.
    public var config: LayoutConfig
    /// Recency order, most recent first (Seats & Pile slice 1). A window moves to the front when
    /// focus lands on it (`touch`), and a window a draw displaces goes to the front of the parked
    /// ones, so the next draw brings it back. Windows not listed rank after listed ones; see `pile`.
    public var mru: [CGWindowID]
    /// The last two windows that traded seats, so promote on the center seat can undo it.
    public var lastTrade: Trade?

    public init(ring: [CGWindowID] = [], centerId: CGWindowID? = nil, cols: Int = 3,
                emphasis: Emphasis = .focus, pins: [Slot: CGWindowID] = [:], focusSlot: Slot = .C,
                config: LayoutConfig = .default, mru: [CGWindowID] = []) {
        self.ring = ring
        self.centerId = centerId
        self.cols = cols
        self.emphasis = emphasis
        self.pins = pins
        self.focusSlot = focusSlot
        self.config = config
        self.mru = mru
        self.lastTrade = nil
    }

    /// The slot keys present for the current column count (`slotKeysFor`, prototype line 162).
    public var slots: [Slot] {
        switch cols {
        case 1: return [.C]
        case 2: return [.L, .R]
        default: return [.L, .C, .R]
        }
    }

    /// The anchor slot the centered window lands in (`primaryFor`, prototype line 163).
    public var primarySlot: Slot {
        cols == 2 ? .L : .C
    }

    /// Preferred landing order for a freshly-opened window: the centered/primary slot first, then
    /// right, then left. Used by `insertManaged` to honor the user's center→right→left preference.
    public var newWindowSlotPreference: [Slot] {
        switch cols {
        case 1: return [.C]
        case 2: return [.L, .R]
        default: return [.C, .R, .L]
        }
    }

    /// The slot a seat key names for the current column count: L / C / R in 3-up; in 2-up L acts as
    /// the center, so U and I both mean L; in monocle every key means C.
    public func seat(for key: SeatKey) -> Slot {
        switch (cols, key) {
        case (1, _): return .C
        case (2, .o): return .R
        case (2, _): return .L
        case (_, .u): return .L
        case (_, .i): return .C
        case (_, .o): return .R
        }
    }

    /// The parked windows in draw order: `pile[0]` is the next draw. Listed in `mru` order; windows
    /// `mru` doesn't know yet follow, nearest to the center first (right before left), which seeds
    /// the order from today's ring.
    public var pile: [CGWindowID] {
        let r = StripLayout(self).resolve()
        let shown = Set(r.assign.values)
        let rank = Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        func distance(_ id: CGWindowID) -> (Int, Int) {
            guard let up = r.unpinned.firstIndex(of: id) else { return (Int.max, 0) }
            var d = posMod(up - r.centerPos, r.m)
            if Double(d) > Double(r.m) / 2 { d -= r.m }
            return (abs(d), d < 0 ? 1 : 0)
        }
        return ring.filter { !shown.contains($0) }.sorted { a, b in
            let ra = rank[a] ?? Int.max, rb = rank[b] ?? Int.max
            if ra != rb { return ra < rb }
            return distance(a) < distance(b)
        }
    }

    /// Focus landed on window `id`: move it to the front of the recency order.
    public mutating func touch(_ id: CGWindowID) {
        guard ring.contains(id) else { return }
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
    }

    /// Drop windows that left the ring from the recency order and the last trade.
    public mutating func pruneMRU() {
        let members = Set(ring)
        mru.removeAll { !members.contains($0) }
        if let t = lastTrade, !members.contains(t.a) || !members.contains(t.b) { lastTrade = nil }
    }

    // MARK: - Mutations

    /// Pin or unpin the focused slot. Pinning fixes whatever window currently occupies the focused
    /// slot so it stays put while the rest of the ring flows past; unpinning lets it flow again.
    /// Focus stays on the slot just pinned (a pinned window is still focusable). If the centered
    /// window itself gets pinned, the *center* (the rotation anchor) moves to the first still-unpinned
    /// window — but focus and the focus ring remain on the pinned window.
    ///
    /// Pure (mutates only `self`) so the state transition is unit-testable without AppKit/AX.
    public mutating func togglePin() {
        let fs = focusSlot
        if pins[fs] != nil {
            pins[fs] = nil                       // unpin
            clampToValidSlots()
            return
        }
        guard let id = StripLayout(self).assignment()[fs] else { return } // empty slot → nothing to pin
        pins[fs] = id                            // pin the window currently in the focused slot
        // Focus stays on `fs` — a pinned window remains focusable (ring + emphasis hold on it).
        let pinned = Set(pins.values)
        if let c = centerId, pinned.contains(c) {                         // center got pinned →
            centerId = ring.first { !pinned.contains($0) } ?? c           // hand rotation anchor to first unpinned
        }
        clampToValidSlots()
    }

    /// Bring a window to the anchor (center) slot — the rail-chip click. If the window is currently
    /// pinned, unpin it first so it can flow to the anchor; focus returns to the primary slot.
    /// Faithful port of the prototype's `setCenter` (`Strip Window Manager.dc.html`, lines 327-333).
    public mutating func setCenter(_ id: CGWindowID) {
        guard ring.contains(id) else { return }
        if let ps = pins.first(where: { $0.value == id })?.key { pins[ps] = nil }
        centerId = id
        focusSlot = primarySlot
        clampToValidSlots()
    }

    /// Put window `new` exactly where `old` was — same ring position, center, and pin — and drop
    /// `old`. For an AppKit native tab switch: each tab is its own window, so switching swaps which
    /// window id is on screen while it stays the same pane to the user. No-op unless `old` is in the
    /// ring and `new` isn't.
    public mutating func replaceWindow(_ old: CGWindowID, with new: CGWindowID) {
        guard let i = ring.firstIndex(of: old), !ring.contains(new) else { return }
        ring[i] = new
        if centerId == old { centerId = new }
        if let slot = pins.first(where: { $0.value == old })?.key { pins[slot] = new }
        if let j = mru.firstIndex(of: old) { mru[j] = new }
        lastTrade = nil
    }

    /// Absorb a freshly-discovered window into the film, positioned per `placement`. Pure (mutates
    /// only `self`) so the placement logic is unit-testable without AppKit/AX.
    ///
    /// `.append` drops it at the end of the ring, out of the way, without stealing focus.
    /// `.focusCenter` brings it to the preferred *unpinned* slot — center, else right, else left —
    /// and gives that slot keyboard focus. In the common case (center slot free) the new window is
    /// inserted into the film **right after the currently-focused window** and made the center, so
    /// it opens next to your working context (niri-style) rather than stranded at the film's end;
    /// the previously-focused window flows into the slot immediately to its left. When the center
    /// slot is pinned the new window lands in the next preferred slot by inserting into the unpinned
    /// sequence at the offset `resolve()` maps to that slot, leaving the pinned window untouched.
    public mutating func insertManaged(_ id: CGWindowID, placement: NewWindowPlacement) {
        guard !ring.contains(id) else { return }

        if placement == .append {
            ring.append(id)
            if centerId == nil { centerId = id }
            return
        }

        let pinnedSet = Set(pins.values)
        var unpinned = ring.filter { !pinnedSet.contains($0) }
        let unpinnedSlots = slots.filter { pins[$0] == nil }

        // No unpinned slot to show it in (every slot pinned) → tuck it at the end of the film.
        guard let target = newWindowSlotPreference.first(where: { pins[$0] == nil }) else {
            ring.append(id)
            if centerId == nil { centerId = id }
            return
        }

        // The slot the centered window occupies (resolve()'s anchor): primary if unpinned, else
        // the first unpinned slot.
        let anchorSlot = unpinnedSlots.contains(primarySlot) ? primarySlot : (unpinnedSlots.first ?? primarySlot)

        // Common case: the preferred slot is the anchor → the new window becomes the center, opened
        // right after the currently-focused window so the film stays contiguous with your context.
        if target == anchorSlot || unpinned.isEmpty {
            let focusedId = StripLayout(self).assignment()[focusSlot]
            if let focusedId, let fi = unpinned.firstIndex(of: focusedId) {
                unpinned.insert(id, at: fi + 1)               // right of focus
                ring = reorderedRing(unpinned: unpinned, pinnedSet: pinnedSet)
            } else {
                ring.append(id)                               // no focus context (e.g. empty strip)
            }
            centerId = id
            focusSlot = target
            clampToValidSlots()
            return
        }

        // Center slot is pinned: land the new window in `target` by inserting it into the unpinned
        // sequence at the position resolve() maps to that slot, relative to the (unchanged) center.
        let anchorIdx = unpinnedSlots.firstIndex(of: anchorSlot) ?? 0
        let targetIdx = unpinnedSlots.firstIndex(of: target) ?? anchorIdx
        let centerPos = centerId.flatMap { unpinned.firstIndex(of: $0) } ?? 0
        let insertAt = max(0, min(unpinned.count, centerPos + (targetIdx - anchorIdx)))
        unpinned.insert(id, at: insertAt)
        ring = reorderedRing(unpinned: unpinned, pinnedSet: pinnedSet)
        focusSlot = target
        clampToValidSlots()
    }

    /// Rebuild the ring so its unpinned subsequence equals `unpinned` (in order) while pinned
    /// windows keep their original ring positions. (`resolve()` only cares about the relative order
    /// of unpinned ids, so this preserves pin slots while reordering the film.)
    private func reorderedRing(unpinned: [CGWindowID], pinnedSet: Set<CGWindowID>) -> [CGWindowID] {
        var rebuilt: [CGWindowID] = []
        var ui = 0
        for old in ring {
            if pinnedSet.contains(old) {
                rebuilt.append(old)
            } else if ui < unpinned.count {
                rebuilt.append(unpinned[ui]); ui += 1
            }
        }
        while ui < unpinned.count { rebuilt.append(unpinned[ui]); ui += 1 }
        return rebuilt
    }

    /// Swap the ring positions of `a` and `b`. Every other window keeps its slot, so only these two
    /// move. If either one was the (resolved) center, the other becomes it: the anchor slot shows
    /// `centerId` by identity, not by ring position (see `resolve()`).
    private mutating func swapInRing(_ a: CGWindowID, _ b: CGWindowID) {
        guard let ia = ring.firstIndex(of: a), let ib = ring.firstIndex(of: b) else { return }
        let center = StripLayout(self).resolve().centerId
        ring.swapAt(ia, ib)
        centerId = center == a ? b : (center == b ? a : center)
    }

    /// Draw `pile[0]` into `seat` (⌃⌥U / I / O): the two windows swap, so nothing else moves, and the
    /// displaced window goes to the top of the pile, so drawing again toggles back. A draw into the
    /// primary seat (C; L in 2-up) moves focus there; a draw into a satellite leaves focus where it
    /// was. An explicit draw works on a locked seat too: the lock stays and now holds the drawn
    /// window. Returns nil (no-op) when the pile is empty or the seat is empty.
    @discardableResult
    public mutating func draw(into seat: Slot) -> Draw? {
        guard slots.contains(seat) else { return nil }
        let r = StripLayout(self).resolve()
        guard let displaced = r.assign[seat], let drawn = pile.first, drawn != displaced else { return nil }
        swapInRing(displaced, drawn)
        if pins[seat] == displaced { pins[seat] = drawn }
        mru.removeAll { $0 == displaced }
        if seat == primarySlot {
            focusSlot = seat
            touch(drawn)
            mru.insert(displaced, at: min(1, mru.count))
        } else {
            mru.insert(displaced, at: 0)
        }
        clampToValidSlots()
        return Draw(drawn: drawn, displaced: displaced, seat: seat)
    }

    /// Trade the focused window with the window in `target` (⌃⌥⇧U / I / O): a two-window swap, and
    /// focus goes with the focused window. Any pair works, L↔R included. No-op in monocle, on an
    /// empty or locked seat, or when `target` is the focused seat. Records `lastTrade`.
    @discardableResult
    public mutating func trade(with target: Slot) -> Trade? {
        guard cols > 1, slots.contains(target) else { return nil }
        let r = StripLayout(self).resolve()
        let from = r.focusSlot
        guard from != target, pins[from] == nil, pins[target] == nil,
              let a = r.assign[from], let b = r.assign[target], a != b else { return nil }
        swapInRing(a, b)
        focusSlot = target
        let t = Trade(a: a, b: b, from: from, to: target)
        lastTrade = t
        clampToValidSlots()
        return t
    }

    /// Promote (⌃⌥↩; ⌃⌥⇧I from a satellite is the same trade): the focused satellite's window trades
    /// into the primary seat and focus goes with it. With focus already on the primary seat, this
    /// undoes `lastTrade` instead: the same two windows trade back (trade ∘ trade = id), and focus
    /// stays on the primary seat. No-op in monocle.
    @discardableResult
    public mutating func promote() -> Trade? {
        guard cols > 1 else { return nil }
        let r = StripLayout(self).resolve()
        if r.focusSlot != primarySlot { return trade(with: primarySlot) }
        guard let t = lastTrade,
              let sa = r.assign.first(where: { $0.value == t.a })?.key,
              let sb = r.assign.first(where: { $0.value == t.b })?.key,
              sa != sb, pins[sa] == nil, pins[sb] == nil else { return nil }
        swapInRing(t.a, t.b)
        let undo = Trade(a: t.a, b: t.b, from: sa, to: sb)
        lastTrade = undo
        return undo
    }

    /// Promote window `id`, which the user committed to in a visible satellite (a committed click,
    /// ⌘Tab), into the primary seat; focus goes with it. Never from a locked seat, from the primary
    /// seat itself, or in monocle.
    @discardableResult
    public mutating func promote(_ id: CGWindowID) -> Trade? {
        guard cols > 1,
              let slot = StripLayout(self).assignment().first(where: { $0.value == id })?.key,
              slot != primarySlot, pins[slot] == nil else { return nil }
        let saved = focusSlot
        focusSlot = slot
        guard let t = trade(with: primarySlot) else { focusSlot = saved; return nil }
        return t
    }

    /// Follow focus that arrived from outside Strip (a click, ⌘Tab, Dock) into window `id`: put
    /// `focusSlot` on the visible slot showing it. Moves nothing — the film and the center stay — so
    /// J/K continue from the window you're actually in. Returns the slot followed to, or nil when
    /// `id` isn't showing in a slot (parked, or not in the ring). Pure → unit-testable.
    @discardableResult
    public mutating func focusFollow(_ id: CGWindowID) -> Slot? {
        guard let slot = StripLayout(self).assignment().first(where: { $0.value == id })?.key else { return nil }
        focusSlot = slot
        return slot
    }

    /// Bring parked window `id` into the anchor (center) slot by swapping it with the window shown
    /// there — a two-entry ring swap, so every other window keeps its slot and only these two move
    /// (Seats & Pile slice 0: a summoned parked window is drawn into C; the old center takes its
    /// place in the film, parked). Focus goes to the anchor. Returns the displaced center's id, or nil
    /// (no-op) when `id` isn't in the ring, is pinned, or is already showing in a slot.
    @discardableResult
    public mutating func summon(_ id: CGWindowID) -> CGWindowID? {
        let r = StripLayout(self).resolve()
        guard r.unpinned.contains(id), !r.assign.values.contains(id),
              let anchor = r.unpinnedSlots.indices.contains(r.anchorIdx) ? r.unpinnedSlots[r.anchorIdx] : nil,
              let old = r.assign[anchor],
              let i = ring.firstIndex(of: id), let j = ring.firstIndex(of: old) else { return nil }
        ring.swapAt(i, j)
        centerId = id
        focusSlot = anchor
        touch(id)
        mru.removeAll { $0 == old }
        mru.insert(old, at: min(1, mru.count)) // the displaced center tops the pile
        clampToValidSlots()
        return old
    }

    /// The slot focus lands on after moving `dir` (+1 right / −1 left) across the *occupied* slots —
    /// pinned slots included, so a pinned window is reachable. Clamps at the ends (no wrap), matching
    /// the existing focus-edge behavior. Pure, so J/K navigation is unit-testable without AppKit/AX.
    public func focusSlotAfterMove(_ dir: Int) -> Slot {
        let assign = StripLayout(self).assignment()
        let occupied = slots.filter { assign[$0] != nil }
        guard !occupied.isEmpty else { return focusSlot }
        let i = occupied.firstIndex(of: focusSlot) ?? 0
        let ni = min(max(0, i + dir), occupied.count - 1)
        return occupied[ni]
    }

    /// Drop pins on slots that don't exist for the current column count and clamp focus to a valid
    /// slot. A safety net after mutations that could leave stale slot keys behind.
    mutating func clampToValidSlots() {
        let keys = slots
        pins = pins.filter { keys.contains($0.key) }
        if !keys.contains(focusSlot) { focusSlot = primarySlot }
    }
}

/// Positive modulo (Swift's `%` keeps the sign of the dividend; the prototype relies on JS's
/// `((x % m) + m) % m` idiom for wrap-around).
@inline(__always)
func posMod(_ a: Int, _ n: Int) -> Int {
    guard n > 0 else { return 0 }
    let r = a % n
    return r < 0 ? r + n : r
}

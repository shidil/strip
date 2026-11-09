import CoreGraphics

/// How the Table absorbs what happens to real windows (`docs/design/seats-and-pile.md`,
/// *Interactions*: new window, close, hide / minimize, restore). These are automatic operations,
/// so they never change what a locked seat shows, except to keep the primary seat filled.
public extension Table {
    // MARK: - New windows

    /// Admit new window `id`. A **focused** new window (⌘N, an app launch) goes into the primary
    /// seat, or the first unlocked seat (R, then L) when C is locked, takes focus, and the window it
    /// displaces tops the pile. A **background** window goes to the top of the pile (`atBottom`: to
    /// the bottom, for the "append" placement). If every seat is locked the window goes to the pile.
    /// The first window of an empty table always takes the primary seat. No-op for a known window.
    @discardableResult
    mutating func add(_ id: CGWindowID, focused: Bool, atBottom: Bool = false) -> Slot? {
        guard !contains(id) else { return nil }
        if seats[primary] == nil {
            seats[primary] = id
            normalize()
            return primary
        }
        if focused, let seat = landingOrder.first(where: { !locks.contains($0) }) {
            if let displaced = seats[seat] { pile.insert(displaced, at: 0) }
            seats[seat] = id
            focusSeat = seat
            normalize()
            return seat
        }
        if atBottom { pile.append(id) } else { pile.insert(id, at: 0) }
        return nil
    }

    // MARK: - Closing

    /// Window `id` is gone. A pile card or hole is simply dropped. A face-up window's seat refills
    /// with `preferred` (the window macOS just focused) when it's in the pile, else `pile[0]`, so a
    /// close is one cut. A locked satellite isn't refilled: it stays empty and loses its lock. With
    /// an empty pile a satellite stays empty, and an empty primary seat promotes the most recently
    /// used satellite (`recent`, most recent first; unlocked ones first). Returns the window that
    /// refilled the seat, if any.
    @discardableResult
    mutating func remove(_ id: CGWindowID, preferred: CGWindowID? = nil, recent: [CGWindowID] = []) -> CGWindowID? {
        defer {
            if let t = lastTrade, !contains(t.a) || !contains(t.b) { lastTrade = nil }
            normalize()
        }
        if let i = pile.firstIndex(of: id) {
            pile.remove(at: i)
            return nil
        }
        if let s = hole(of: id) {
            holes[s] = nil
            return nil
        }
        if let i = hidden.firstIndex(of: id) {
            hidden.remove(at: i)
            return nil
        }
        guard let s = seat(of: id) else { return nil }
        seats[s] = nil
        if s != primary, locks.contains(s) {
            locks.remove(s)
            return nil
        }
        return refill(s, preferred: preferred, recent: recent)
    }

    // MARK: - Hide / minimize and restore

    /// Window `id` was hidden or minimized. A satellite becomes a **hole**: no refill, so nothing
    /// collides when macOS restores the window to its own frame. The primary seat becomes a hole
    /// *and* is refilled (one cut), because C is never empty. A pile card becomes `hidden`, so it's
    /// never drawn while you can't see it. Returns the refill, if any.
    @discardableResult
    mutating func hide(_ id: CGWindowID, preferred: CGWindowID? = nil, recent: [CGWindowID] = []) -> CGWindowID? {
        if let i = pile.firstIndex(of: id) {
            pile.remove(at: i)
            hidden.append(id)
            return nil
        }
        guard let s = seat(of: id), holes[s] == nil else { return nil }
        seats[s] = nil
        holes[s] = id
        defer { normalize() }
        return s == primary ? refill(s, preferred: preferred, recent: recent) : nil
    }

    /// Hidden window `id` came back (un-minimize, unhide). From a hole it takes its seat back, and
    /// whatever filled the seat meanwhile tops the pile: one visible change, since the window
    /// restores into the seat's rect. A `hidden` window (it was in the pile, or its seat went away
    /// with a column change) is summoned: the user brought it back, so it lands somewhere visible.
    /// Returns the seat it landed in.
    @discardableResult
    mutating func restore(_ id: CGWindowID) -> Slot? {
        if let s = hole(of: id) {
            holes[s] = nil
            if let occupant = seats[s] { pile.insert(occupant, at: 0) }
            seats[s] = id
            // Everything was hidden, so C is an empty hole: the window you brought back fills it.
            if seats[primary] == nil { _ = refill(primary, preferred: nil, recent: []) }
            normalize()
            return seat(of: id)
        }
        guard let i = hidden.firstIndex(of: id) else { return nil }
        hidden.remove(at: i)
        pile.insert(id, at: 0)
        return summon(id)
    }

    // MARK: - Native tabs

    /// Window `new` replaces `old` wherever `old` is: a seat, a hole or the pile. An AppKit native
    /// tab switch shows a different window id that is the same pane to the user. No-op unless `old`
    /// is managed and `new` isn't. Drops `lastTrade` (as the ring's `replaceWindow` did).
    @discardableResult
    mutating func replace(_ old: CGWindowID, with new: CGWindowID) -> Bool {
        guard contains(old), !contains(new) else { return false }
        if let s = seat(of: old) { seats[s] = new }
        if let s = hole(of: old) { holes[s] = new }
        if let i = pile.firstIndex(of: old) { pile[i] = new }
        if let i = hidden.firstIndex(of: old) { hidden[i] = new }
        lastTrade = nil
        return true
    }

    // MARK: - Startup adoption

    /// Adopt windows into an empty table (startup, or after every window closed), given front to
    /// back. A window already sitting in a seat's rect (within `tolerance` of its size; Strip was
    /// restarted) takes that seat. The primary seat then takes `focused`, else the frontmost
    /// window; other empty seats take the next windows front to back (R, then L); the rest form the
    /// pile front to back. Focus lands on `focused`'s seat, else the primary seat.
    mutating func adopt(_ windows: [(id: CGWindowID, frame: CGRect)], focused: CGWindowID?,
                        on stage: Stage, tolerance: CGFloat = 24) {
        let rects = seatRects(on: stage)
        var left = windows.filter { !contains($0.id) }
        func take(_ i: Int, into s: Slot) {
            seats[s] = left[i].id
            left.remove(at: i)
        }
        for s in landingOrder where seats[s] == nil {
            guard let r = rects[s] else { continue }
            if let i = left.firstIndex(where: { w in
                r.contains(CGPoint(x: w.frame.midX, y: w.frame.midY))
                    && abs(w.frame.width - r.width) <= tolerance && abs(w.frame.height - r.height) <= tolerance
            }) { take(i, into: s) }
        }
        if seats[primary] == nil, !left.isEmpty {
            take(left.firstIndex { $0.id == focused } ?? 0, into: primary)
        }
        for s in landingOrder where seats[s] == nil && !left.isEmpty { take(0, into: s) }
        pile += left.map(\.id)
        focusSeat = focused.flatMap { seat(of: $0) } ?? primary
        normalize()
    }

    // MARK: - Refill

    /// Fill empty seat `s`: with `preferred` if it's in the pile, else `pile[0]`; for the primary
    /// seat with an empty pile, promote the most recent satellite (unlocked first; a locked one gives
    /// up its lock, since the primary seat must not stay empty).
    private mutating func refill(_ s: Slot, preferred: CGWindowID?, recent: [CGWindowID]) -> CGWindowID? {
        if let p = preferred, let i = pile.firstIndex(of: p) {
            pile.remove(at: i)
            seats[s] = p
            return p
        }
        if let next = pile.first {
            pile.removeFirst()
            seats[s] = next
            return next
        }
        guard s == primary else { return nil }
        let rank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let order = landingOrder
        let candidates = order.filter { $0 != primary && seats[$0] != nil }.sorted { a, b in
            let la = locks.contains(a), lb = locks.contains(b)
            if la != lb { return !la }
            let ra = rank[seats[a]!] ?? Int.max, rb = rank[seats[b]!] ?? Int.max
            if ra != rb { return ra < rb }
            return order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
        guard let from = candidates.first, let id = seats[from] else { return nil }
        seats[from] = nil
        locks.remove(from)
        seats[s] = id
        return id
    }
}

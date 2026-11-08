import CoreGraphics

/// The Table's verbs (`docs/design/seats-and-pile.md`, *Interactions*). Each one is a pure mutation
/// that returns whether anything changed; the motion it implies comes from diffing the before and
/// after tables (`transitions(from:to:…)`), so the verbs never think about frames.
///
/// The rule for every verb: **a displaced window goes back where its replacement came from**. A
/// window drawn from the pile sends the displaced one to the top of the pile, so the same verb again
/// toggles back; a window that comes from another seat trades seats with it.
public extension Table {
    // MARK: - Draw (⌃⌥U / I / O)

    /// Draw `pile[0]` into `seat`. The displaced window tops the pile, so drawing again toggles
    /// back. A draw into the primary seat focuses it; a satellite draw leaves focus where it was.
    /// Explicit, so it works on a locked seat (the lock stays and now holds the drawn window) and on
    /// an empty seat. A seat's hole stays: the restore sorts out who keeps the seat.
    @discardableResult
    mutating func draw(into seat: Slot) -> Bool {
        guard slots.contains(seat), let drawn = pile.first else { return false }
        pile.removeFirst()
        if let displaced = seats[seat] { pile.insert(displaced, at: 0) }
        seats[seat] = drawn
        if seat == primary { focusSeat = seat }
        normalize()
        return true
    }

    // MARK: - Trade (⌃⌥⇧U / I / O) and promote (⌃⌥↩)

    /// Trade the focused window with the window in `target`; focus goes with the focused window.
    /// Any pair works, L↔R included. No-op in monocle, onto itself, on an empty seat, or when either
    /// seat is locked. Records `lastTrade`.
    @discardableResult
    mutating func trade(with target: Slot) -> Bool {
        let from = focusSeat
        guard cols > 1, slots.contains(target), from != target,
              !locks.contains(from), !locks.contains(target),
              let a = seats[from], let b = seats[target] else { return false }
        seats[from] = b
        seats[target] = a
        focusSeat = target
        lastTrade = Trade(a: a, b: b, from: from, to: target)
        return true
    }

    /// Promote: the focused satellite trades into the primary seat and focus goes with it. With
    /// focus already on the primary seat, undo `lastTrade` instead (the same two windows trade back,
    /// `trade ∘ trade = id`), and focus stays. No-op in monocle.
    @discardableResult
    mutating func promote() -> Bool {
        guard cols > 1 else { return false }
        if focusSeat != primary { return trade(with: primary) }
        guard let t = lastTrade, let sa = seat(of: t.a), let sb = seat(of: t.b), sa != sb,
              !locks.contains(sa), !locks.contains(sb) else { return false }
        seats[sa] = t.b
        seats[sb] = t.a
        lastTrade = Trade(a: t.a, b: t.b, from: sa, to: sb)
        return true
    }

    /// Promote window `id`, which the user committed to in a visible satellite (a committed click,
    /// ⌘Tab), into the primary seat; focus goes with it. Never from a locked seat, the primary seat
    /// itself, the pile, or in monocle.
    @discardableResult
    mutating func promote(_ id: CGWindowID) -> Bool {
        guard cols > 1, let s = seat(of: id), s != primary, !locks.contains(s) else { return false }
        let saved = focusSeat
        focusSeat = s
        if trade(with: primary) { return true }
        focusSeat = saved
        return false
    }

    // MARK: - Pick (Overview, search, rail) and summon

    /// Put window `id` into `seat`: a **draw** when it's in the pile (the displaced window tops the
    /// pile), a **trade** when it's in another seat (recorded in `lastTrade`). A pick into the
    /// primary seat focuses it; into a satellite, focus stays where it was. Explicit, so it works on
    /// locked seats and the locks stay with their seats. Moving the primary window into an empty
    /// satellite refills the primary seat from the pile, and is refused when the pile is empty (the
    /// primary seat is never left empty). No-op for unknown or hidden windows.
    @discardableResult
    mutating func pick(_ id: CGWindowID, into seat: Slot) -> Bool {
        guard slots.contains(seat), hole(of: id) == nil else { return false }
        if let from = self.seat(of: id) {
            if from == seat {
                guard seat == primary, focusSeat != primary else { return false }
                focusSeat = primary
                return true
            }
            if let other = seats[seat] {
                seats[from] = other
                lastTrade = Trade(a: id, b: other, from: from, to: seat)
            } else if from == primary {
                guard let refill = pile.first else { return false }
                pile.removeFirst()
                seats[from] = refill
            } else {
                seats[from] = nil
            }
            seats[seat] = id
        } else if let i = pile.firstIndex(of: id) {
            pile.remove(at: i)
            if let displaced = seats[seat] { pile.insert(displaced, at: 0) }
            seats[seat] = id
        } else {
            return false
        }
        if seat == primary { focusSeat = primary }
        normalize()
        return true
    }

    /// Summon window `id` from the pile into `landingSeat` (the primary seat unless it's locked):
    /// the user focused a parked window (⌘Tab, Dock, a notification). Returns the seat it landed in,
    /// or nil when `id` isn't in the pile.
    @discardableResult
    mutating func summon(_ id: CGWindowID) -> Slot? {
        guard pile.contains(id) else { return nil }
        let seat = landingSeat
        return pick(id, into: seat) ? seat : nil
    }

    // MARK: - Focus

    /// Focus arrived in window `id` from outside Strip: move `focusSeat` to its seat. Moves no
    /// window. Returns the seat, or nil when `id` isn't seated.
    @discardableResult
    mutating func focusFollow(_ id: CGWindowID) -> Slot? {
        guard let s = seat(of: id) else { return nil }
        focusSeat = s
        return s
    }

    /// Look without moving (⌃⌥J / K): step focus `dir` (+1 right, −1 left) across the occupied seats,
    /// locked ones included. Clamps at the ends.
    @discardableResult
    mutating func look(_ dir: Int) -> Bool {
        let occupied = slots.filter { seats[$0] != nil }
        guard !occupied.isEmpty else { return false }
        let i = occupied.firstIndex(of: focusSeat) ?? 0
        let next = occupied[min(max(0, i + dir), occupied.count - 1)]
        guard next != focusSeat else { return false }
        focusSeat = next
        return true
    }

    // MARK: - Lock (⌃⌥P)

    /// Lock or unlock the focused seat. An empty seat can't be locked. Focus stays.
    @discardableResult
    mutating func toggleLock() -> Bool {
        if locks.contains(focusSeat) {
            locks.remove(focusSeat)
            return true
        }
        guard seats[focusSeat] != nil else { return false }
        locks.insert(focusSeat)
        return true
    }

    // MARK: - Pass (⌃⌥H / L)

    /// Pass (the old slide, now bounded and reversible): shift the occupied, unlocked seats without a
    /// hole one step. `dir` +1 (⌃⌥L) moves every window one seat left: the leftmost goes to the top
    /// of the pile and `pile[0]` takes the rightmost seat. −1 mirrors it. So `pass(-1) ∘ pass(+1) =
    /// id`, and holding the key cycles the cols + 1 most recent cards. With an empty pile the seats
    /// rotate. Focus stays on its seat; `lastTrade` is dropped. In monocle this toggles like a draw.
    @discardableResult
    mutating func pass(_ dir: Int) -> Bool {
        guard dir != 0 else { return false }
        let movable = slots.filter { !locks.contains($0) && holes[$0] == nil && seats[$0] != nil }
        guard !movable.isEmpty else { return false }
        var row = movable.compactMap { seats[$0] }
        if let incoming = pile.first {
            pile.removeFirst()
            let outgoing = dir > 0 ? row.removeFirst() : row.removeLast()
            pile.insert(outgoing, at: 0)
            if dir > 0 { row.append(incoming) } else { row.insert(incoming, at: 0) }
        } else {
            guard row.count > 1 else { return false }
            if dir > 0 { row.append(row.removeFirst()) } else { row.insert(row.removeLast(), at: 0) }
        }
        for (s, id) in zip(movable, row) { seats[s] = id }
        lastTrade = nil
        normalize()
        return true
    }

    // MARK: - Columns (⌃⌥1 / 2 / 3)

    /// Change the column count.
    ///
    /// - **Growing** keeps the primary window in the new primary seat and a satellite that still
    ///   exists in its seat, then draws `pile[0]` into R and `pile[1]` into L.
    /// - **Going to monocle**: the focused window becomes C and the old primary window tops the pile.
    /// - **3 → 2**: C's window takes L (the 2-up center); R keeps the focused satellite if there is
    ///   one, else its own window, else L's.
    ///
    /// Windows that lose their seat go to the top of the pile: the old primary first, then R, then
    /// L. Holes on seats that go away move to the bottom of the pile; the primary seat's hole
    /// follows the primary seat. A lock survives only on a seat that keeps its window. `lastTrade`
    /// is dropped.
    @discardableResult
    mutating func setCols(_ n: Int) -> Bool {
        guard (1...3).contains(n), n != cols else { return false }
        let old = self
        let newSlots = Table.slots(cols: n)
        let newPrimary = Table.primary(cols: n)
        let oldPrimaryId = old.seats[old.primary]
        let focused = old.focusedId
        var newSeats: [Slot: CGWindowID] = [:]
        var placed = Set<CGWindowID>()
        func place(_ id: CGWindowID?, _ s: Slot) {
            guard let id, !placed.contains(id), newSeats[s] == nil else { return }
            newSeats[s] = id
            placed.insert(id)
        }

        var newPile = old.pile
        if n < old.cols {
            place(n == 1 ? (focused ?? oldPrimaryId) : oldPrimaryId, newPrimary)
            for s in newSlots where s != newPrimary {
                let focusedSatellite = old.focusSeat != old.primary ? focused : nil
                for candidate in [focusedSatellite, old.seats[s], old.seats[.R], old.seats[.L]] {
                    place(candidate, s)
                }
            }
            let leftovers = [oldPrimaryId, old.seats[.R], old.seats[.L], old.seats[.C]]
                .compactMap { $0 }.filter { !placed.contains($0) }
            var seen = Set<CGWindowID>()
            newPile = leftovers.filter { seen.insert($0).inserted } + newPile
        } else {
            place(oldPrimaryId, newPrimary)
            for s in newSlots where s != newPrimary && old.slots.contains(s) { place(old.seats[s], s) }
            for s in [Slot.R, .L] where newSlots.contains(s) && newSeats[s] == nil {
                guard let next = newPile.first else { break }
                newPile.removeFirst()
                place(next, s)
            }
        }

        var newHoles: [Slot: CGWindowID] = [:]
        for (s, id) in old.holes {
            let target = s == old.primary ? newPrimary : s
            if newSlots.contains(target), newHoles[target] == nil { newHoles[target] = id } else { newPile.append(id) }
        }

        seats = newSeats
        pile = newPile
        holes = newHoles
        cols = n
        locks = Set(old.locks.filter { s in newSlots.contains(s) && newSeats[s] != nil && newSeats[s] == old.seats[s] })
        focusSeat = focused.flatMap { id in newSeats.first { $0.value == id }?.key } ?? newPrimary
        lastTrade = nil
        normalize()
        return true
    }

    // MARK: - Repair

    /// Keep focus and locks on seats that exist: drop locks on seats `cols` doesn't have, and move
    /// focus off an empty or missing seat to the primary seat (else the first occupied one).
    mutating func normalize() {
        let keys = slots
        locks = locks.filter { keys.contains($0) }
        if !keys.contains(focusSeat) { focusSeat = primary }
        if seats[focusSeat] == nil {
            focusSeat = seats[primary] != nil ? primary : (keys.first { seats[$0] != nil } ?? primary)
        }
    }
}

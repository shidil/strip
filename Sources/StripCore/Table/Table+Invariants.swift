import CoreGraphics

public extension Table {
    /// Every broken invariant, as a readable message; empty when the table is sound. The design
    /// doc's invariants (*Pure state*) that are properties of one table:
    ///
    /// - every managed window is in exactly one of `seats`, `pile`, `holes` or `hidden`;
    /// - the primary seat is never empty while any face-up or face-down card exists;
    ///
    /// plus the structural ones the verbs rely on: seat, hole and lock keys exist for `cols`, focus
    /// is on an existing seat (an occupied one whenever any seat is), `lastTrade` names managed
    /// windows, and `cols` is 1–3. The invariants about verbs (`trade ∘ trade = id`,
    /// `pass(h) ∘ pass(l) = id`, no automatic operation changes a locked seat) are tested on the verbs.
    func invariantViolations() -> [String] {
        var out: [String] = []
        if !(1...3).contains(cols) { out.append("cols \(cols) is not 1–3") }

        var count: [CGWindowID: Int] = [:]
        for id in members { count[id, default: 0] += 1 }
        for (id, n) in count.sorted(by: { $0.key < $1.key }) where n > 1 {
            out.append("window \(id) is in \(n) places")
        }

        let keys = Set(slots)
        for s in seats.keys.sorted(by: order) where !keys.contains(s) { out.append("seat \(s) doesn't exist in \(cols)-up") }
        for s in holes.keys.sorted(by: order) where !keys.contains(s) { out.append("hole \(s) doesn't exist in \(cols)-up") }
        for s in locks.sorted(by: order) where !keys.contains(s) { out.append("lock \(s) doesn't exist in \(cols)-up") }

        if seats[primary] == nil, !seats.isEmpty || !pile.isEmpty {
            out.append("the primary seat \(primary) is empty while cards exist")
        }
        if !keys.contains(focusSeat) {
            out.append("focus is on \(focusSeat), which doesn't exist in \(cols)-up")
        } else if seats[focusSeat] == nil, !seats.isEmpty {
            out.append("focus is on the empty seat \(focusSeat)")
        }
        if let t = lastTrade, !contains(t.a) || !contains(t.b) {
            out.append("lastTrade names a window that isn't managed")
        }
        return out
    }
}

private func order(_ a: Slot, _ b: Slot) -> Bool {
    (Slot.allCases.firstIndex(of: a) ?? 0) < (Slot.allCases.firstIndex(of: b) ?? 0)
}

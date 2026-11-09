import CoreGraphics

/// How one window moves between two tables (`docs/design/seats-and-pile.md`, *Layout*). One motion
/// rule: **content changes cut; position changes spring.**
public enum Transition: Equatable {
    /// No write: the window is where it was (or hidden, which Strip never moves).
    case stay
    /// Glide to the new frame: a seat-to-seat move between neighbors, a resize in place, or a card
    /// sliding in or out under `CardMotion.slide`.
    case spring
    /// An instant swap: a card entering or leaving a seat, a new window, a restore, or an L↔R trade
    /// in 3-up (a spring would drag both windows through C).
    case cut
    /// A parked card moves while parked (its edge flips, or it's resized): invisible, one write.
    case snapOffscreen
}

/// How cards enter and leave seats.
public enum CardMotion: Equatable {
    /// The default: drawn cards appear in place and displaced ones vanish (satellite draws are
    /// instant cuts, owner decision 3).
    case cut
    /// Cards slide in from and out to the edge nearest their seat: pass (⌃⌥H / L), and later the
    /// "Deal" preset.
    case slide
}

/// Where a window is on a table.
enum Spot: Equatable {
    /// `hole` covers both a seat's hole and `Table.hidden`: a window that can't be seen.
    case seat(Slot), pile, hole

    init?(_ id: CGWindowID, on t: Table) {
        if let s = t.seat(of: id) {
            self = .seat(s)
        } else if t.hole(of: id) != nil || t.hidden.contains(id) {
            self = .hole
        } else if t.pile.contains(id) {
            self = .pile
        } else {
            return nil
        }
    }
}

/// The transition of every window that's on `to` (windows only on `from` are gone and need none).
/// `edgesBefore` / `edgesAfter` are the pile's park edges on each table (see `Table.parkEdges`).
/// `previous` is the stage `from` was laid out on, when the geometry itself changed (a display
/// change, a learned size constraint); it defaults to `stage`.
public func transitions(from: Table, to: Table, on stage: Stage, previous: Stage? = nil,
                        edgesBefore: [CGWindowID: Edge] = [:], edgesAfter: [CGWindowID: Edge] = [:],
                        motion: CardMotion = .cut) -> [CGWindowID: Transition] {
    let old = previous ?? stage
    let fromRects = from.seatRects(on: old)
    let toRects = to.seatRects(on: stage)
    let enterOrLeave: Transition = motion == .slide ? .spring : .cut
    var out: [CGWindowID: Transition] = [:]
    for id in to.members {
        guard let b = Spot(id, on: to) else { continue }
        let a = Spot(id, on: from)
        switch (a, b) {
        case (_, .hole), (.hole?, .pile):
            out[id] = .stay // hidden: never moved
        case (nil, _), (.hole?, .seat):
            out[id] = .cut // a new window placed or parked; a restore takes its seat
        case (.pile?, .pile):
            let was = from.parkFrame(for: id, edge: edgesBefore[id] ?? .right, on: old)
            let now = to.parkFrame(for: id, edge: edgesAfter[id] ?? .right, on: stage)
            out[id] = was == now ? .stay : .snapOffscreen
        case let (.seat(s1)?, .seat(s2)):
            if s1 == s2 {
                out[id] = fromRects[s1] == toRects[s2] ? .stay : .spring
            } else {
                out[id] = MotionPolicy.tradeCuts(s1, s2, cols: max(from.cols, to.cols)) ? .cut : .spring
            }
        case (.pile?, .seat), (.seat?, .pile):
            out[id] = enterOrLeave
        }
    }
    return out
}

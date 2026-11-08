import CoreGraphics

/// The Seats & Pile model (`docs/design/seats-and-pile.md`, *The model*): fixed **seats** that each
/// show one window face-up, and one **pile** of every other managed window, most recent first.
/// Seats are places; windows have no neighbors. This replaces the wrapping ring (`StripState`) from
/// step 3 on; until then nothing in the app reads it.
///
/// Pure value type: every verb (`Table+Verbs.swift`) is a deterministic mutation, so the motion it
/// implies (`transitions(from:to:…)`, `MovePlan`) and every invariant (`invariantViolations()`) is
/// unit-testable without AppKit or AX.
public struct Table: Equatable {
    /// Seat → the window shown face-up there. Keys ⊆ `slots`. A satellite may be empty (put away,
    /// or nothing left to draw); the primary seat is never empty while any card exists.
    public var seats: [Slot: CGWindowID]
    /// Every other managed window, face-down, most recent first: `pile[0]` is the next draw.
    public var pile: [CGWindowID]
    /// Seat → a hidden or minimized window that still owns it. Nothing refills a satellite hole, so
    /// nothing collides when macOS restores the window to its own frame. A seat may hold a window
    /// *and* a hole (C is refilled when its window hides); the restore resolves that (step 3).
    public var holes: [Slot: CGWindowID]
    /// Locked seats (today's pins). Pass, new windows, close refills and automatic promotes skip
    /// them; explicit draws and picks still work on them, and the lock stays with the seat.
    public var locks: Set<Slot>
    /// The seat with keyboard focus.
    public var focusSeat: Slot
    /// The last two windows that traded seats, so promote on the primary seat can undo it.
    public var lastTrade: Trade?
    /// Column count: 1 (monocle), 2 or 3.
    public var cols: Int
    public var emphasis: Emphasis
    public var config: LayoutConfig

    public init(seats: [Slot: CGWindowID] = [:], pile: [CGWindowID] = [], holes: [Slot: CGWindowID] = [:],
                locks: Set<Slot> = [], focusSeat: Slot? = nil, lastTrade: Trade? = nil, cols: Int = 3,
                emphasis: Emphasis = .focus, config: LayoutConfig = .default) {
        self.seats = seats
        self.pile = pile
        self.holes = holes
        self.locks = locks
        self.focusSeat = focusSeat ?? Table.primary(cols: cols)
        self.lastTrade = lastTrade
        self.cols = cols
        self.emphasis = emphasis
        self.config = config
    }

    // MARK: - Seats for a column count

    /// The seats that exist for `cols`: L C R in 3-up, L R in 2-up, C in monocle.
    public static func slots(cols: Int) -> [Slot] {
        switch cols {
        case 1: return [.C]
        case 2: return [.L, .R]
        default: return [.L, .C, .R]
        }
    }

    /// The primary seat: C, or L in 2-up (L acts as the center there).
    public static func primary(cols: Int) -> Slot {
        cols == 2 ? .L : .C
    }

    public var slots: [Slot] { Table.slots(cols: cols) }
    public var primary: Slot { Table.primary(cols: cols) }

    /// The seat a seat key (U / I / O) names: L / C / R in 3-up; in 2-up U and I both mean L; in
    /// monocle every key means C.
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

    /// Where a window that must become visible lands, best first: the primary seat, then R, then L
    /// (design: a new window takes C, or "the first unlocked seat, R then L").
    public var landingOrder: [Slot] {
        switch cols {
        case 1: return [.C]
        case 2: return [.L, .R]
        default: return [.C, .R, .L]
        }
    }

    /// The first unlocked seat in `landingOrder`. When every seat is locked, the primary seat: a
    /// summon the user caused always lands somewhere visible, overriding the lock.
    public var landingSeat: Slot {
        landingOrder.first { !locks.contains($0) } ?? primary
    }

    // MARK: - Lookup

    /// The window in the focused seat.
    public var focusedId: CGWindowID? { seats[focusSeat] }

    /// The seat showing `id`, or nil when it's in the pile, a hole, or unknown.
    public func seat(of id: CGWindowID) -> Slot? {
        seats.first { $0.value == id }?.key
    }

    /// The seat whose hole `id` is, or nil.
    public func hole(of id: CGWindowID) -> Slot? {
        holes.first { $0.value == id }?.key
    }

    public func contains(_ id: CGWindowID) -> Bool {
        seat(of: id) != nil || hole(of: id) != nil || pile.contains(id)
    }

    /// Seated windows in seat order (L, C, R).
    public var seated: [CGWindowID] {
        Slot.allCases.compactMap { seats[$0] }
    }

    /// Every managed window: seated (seat order), then holes (seat order), then the pile.
    public var members: [CGWindowID] {
        seated + Slot.allCases.compactMap { holes[$0] } + pile
    }
}

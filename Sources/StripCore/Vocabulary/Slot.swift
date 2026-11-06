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

    public init(a: CGWindowID, b: CGWindowID, from: Slot, to: Slot) {
        self.a = a
        self.b = b
        self.from = from
        self.to = to
    }
}

/// A draw: `drawn` came off the pile into `seat`, and `displaced` went to the top of the pile.
public struct Draw: Equatable {
    public let drawn: CGWindowID
    public let displaced: CGWindowID
    public let seat: Slot

    public init(drawn: CGWindowID, displaced: CGWindowID, seat: Slot) {
        self.drawn = drawn
        self.displaced = displaced
        self.seat = seat
    }
}

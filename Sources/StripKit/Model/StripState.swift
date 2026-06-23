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

    public init(ring: [CGWindowID] = [], centerId: CGWindowID? = nil, cols: Int = 3,
                emphasis: Emphasis = .focus, pins: [Slot: CGWindowID] = [:], focusSlot: Slot = .C) {
        self.ring = ring
        self.centerId = centerId
        self.cols = cols
        self.emphasis = emphasis
        self.pins = pins
        self.focusSlot = focusSlot
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
}

/// Positive modulo (Swift's `%` keeps the sign of the dividend; the prototype relies on JS's
/// `((x % m) + m) % m` idiom for wrap-around).
@inline(__always)
func posMod(_ a: Int, _ n: Int) -> Int {
    guard n > 0 else { return 0 }
    let r = a % n
    return r < 0 ? r + n : r
}

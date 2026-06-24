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
    /// Tunable window-sizing knobs (padding, gaps, focus width ratio) — see `LayoutConfig`.
    public var config: LayoutConfig

    public init(ring: [CGWindowID] = [], centerId: CGWindowID? = nil, cols: Int = 3,
                emphasis: Emphasis = .focus, pins: [Slot: CGWindowID] = [:], focusSlot: Slot = .C,
                config: LayoutConfig = .default) {
        self.ring = ring
        self.centerId = centerId
        self.cols = cols
        self.emphasis = emphasis
        self.pins = pins
        self.focusSlot = focusSlot
        self.config = config
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

    // MARK: - Mutations

    /// Pin or unpin the focused slot. Pinning fixes whatever window currently occupies the focused
    /// slot so it stays put while the rest of the ring flows past; unpinning lets it flow again.
    /// If the centered window itself gets pinned, the center moves to the first still-unpinned
    /// window, and focus moves off any now-pinned slot. Faithful port of the prototype's
    /// `togglePin` (`Strip Window Manager.dc.html`, lines 355-374).
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
        let up = slots.filter { pins[$0] == nil }
        focusSlot = up.contains(primarySlot) ? primarySlot : (up.first ?? fs)
        let pinned = Set(pins.values)
        if let c = centerId, pinned.contains(c) {                         // center got pinned →
            centerId = ring.first { !pinned.contains($0) } ?? c           // hand center to first unpinned
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

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

    /// Preferred landing order for a freshly-opened window: the centered/primary slot first, then
    /// right, then left. Used by `insertManaged` to honor the user's center→right→left preference.
    public var newWindowSlotPreference: [Slot] {
        switch cols {
        case 1: return [.C]
        case 2: return [.L, .R]
        default: return [.C, .R, .L]
        }
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

    /// Swap the window in the *focused* slot with whichever window occupies its immediate neighbor
    /// slot in direction `dir` (+1 right / −1 left) — a clean two-window exchange, guaranteed to land
    /// the carried window in that exact neighbor slot. Keyboard focus rides along with it. No-op if
    /// the focused slot is empty/pinned, or has no unpinned neighbor in that direction (e.g. already
    /// at the strip's edge, or monocle) — pinned windows never move and are skipped over when looking
    /// for a neighbor, since they don't participate in the flow.
    ///
    /// The anchor slot always *displays* `centerId` by identity, not by ring position (see
    /// `resolve()`) — so a swap that moves a window into or out of the anchor slot must also hand
    /// `centerId` to whichever window is now anchoring, or the swap wouldn't actually relocate the
    /// anchor's displayed window (it would keep showing the old centerId, wherever it drifted to).
    /// With cols 1–3 every reachable adjacent slot pair includes the anchor, so this fixup covers
    /// every swap this method can perform today.
    ///
    /// Pure (mutates only `self`) so the swap is unit-testable without AppKit/AX.
    public mutating func moveFocused(_ dir: Int) {
        guard pins[focusSlot] == nil else { return }
        let assign = StripLayout(self).assignment()
        guard let a = assign[focusSlot] else { return }

        let unpinnedSlots = slots.filter { pins[$0] == nil }
        guard let fi = unpinnedSlots.firstIndex(of: focusSlot) else { return }
        let ni = fi + dir
        guard unpinnedSlots.indices.contains(ni) else { return }
        let neighborSlot = unpinnedSlots[ni]
        guard let b = assign[neighborSlot], a != b,
              let ia = ring.firstIndex(of: a), let ib = ring.firstIndex(of: b) else { return }

        ring.swapAt(ia, ib)
        if centerId == a { centerId = b } else if centerId == b { centerId = a }
        focusSlot = neighborSlot
        clampToValidSlots()
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

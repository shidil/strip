import CoreGraphics

/// Where the engine wants a single window to be, in Quartz display coordinates.
public struct WindowPlacement: Equatable {
    public let id: CGWindowID
    /// Target frame (Quartz, top-left origin). For parked windows this is just off the display edge.
    public let frame: CGRect
    /// True for the focused window (the one in `focusSlot`).
    public let active: Bool
    /// True when the window is off the visible strip (slid off an edge).
    public let parked: Bool
    /// The slot this window occupies, or nil when parked.
    public let slot: Slot?
}

/// The pure heart of the strip: given a `StripState` and the display's visible frame, it decides
/// which window occupies which slot (pin-aware ring rotation) and where every window should be.
///
/// This is a faithful port of the prototype's `resolve()` (lines 181-202) and the geometry portion
/// of `computeVM()` (lines 204-265). The 3D/opacity transitions from `computeVM` are intentionally
/// dropped — real app windows can only be moved/resized via the Accessibility API — and "parked"
/// windows are pushed fully off the display edge instead of faded.
public struct StripLayout {
    public var state: StripState
    public init(_ state: StripState) { self.state = state }

    /// Gap between a parked window and the display edge.
    static let parkGap: CGFloat = 40

    // MARK: - resolve()

    struct Resolved {
        let slots: [Slot]
        let pins: [Slot: CGWindowID]
        let unpinned: [CGWindowID]
        let m: Int
        let unpinnedSlots: [Slot]
        let anchorIdx: Int
        let focusSlot: Slot
        let centerId: CGWindowID?
        let centerPos: Int
        let assign: [Slot: CGWindowID]
    }

    func resolve() -> Resolved {
        let slots = state.slots
        let pins = state.pins
        let pinnedSet = Set(pins.values)
        let unpinned = state.ring.filter { !pinnedSet.contains($0) }
        let m = max(unpinned.count, 1)
        let unpinnedSlots = slots.filter { pins[$0] == nil }

        var anchorSlot = state.primarySlot
        if !unpinnedSlots.contains(anchorSlot) { anchorSlot = unpinnedSlots.first ?? anchorSlot }
        let anchorIdx = max(0, unpinnedSlots.firstIndex(of: anchorSlot) ?? 0)

        var centerId = state.centerId
        if centerId == nil || !unpinned.contains(centerId!) { centerId = unpinned.first }
        let centerPos = centerId.flatMap { unpinned.firstIndex(of: $0) } ?? 0

        var assign: [Slot: CGWindowID] = [:]
        for s in slots where pins[s] != nil { assign[s] = pins[s] }
        if !unpinned.isEmpty {
            for (k, s) in unpinnedSlots.enumerated() {
                assign[s] = unpinned[posMod(centerPos + (k - anchorIdx), m)]
            }
        }

        // Focus may rest on any occupied slot — a pinned slot included (pinning doesn't make a window
        // unfocusable). Fall back only when the focused slot has no window at all (too few windows to
        // fill it): prefer the anchor, else the first occupied slot.
        var focusSlot = state.focusSlot
        if assign[focusSlot] == nil {
            focusSlot = assign[anchorSlot] != nil ? anchorSlot : (slots.first { assign[$0] != nil } ?? anchorSlot)
        }

        return Resolved(slots: slots, pins: pins, unpinned: unpinned, m: m,
                        unpinnedSlots: unpinnedSlots, anchorIdx: anchorIdx, focusSlot: focusSlot,
                        centerId: centerId, centerPos: centerPos, assign: assign)
    }

    /// The window id currently in the focused slot, if any.
    public var activeId: CGWindowID? {
        let r = resolve()
        return r.assign[r.focusSlot]
    }

    /// The slot→window assignment for the rail / status chrome.
    public func assignment() -> [Slot: CGWindowID] {
        resolve().assign
    }

    // MARK: - placements()

    /// Target placement for every window in the ring, within `vis` (Quartz coordinates).
    public func placements(in vis: CGRect) -> [WindowPlacement] {
        let r = resolve()
        // geom() uses the raw state.focusSlot (prototype line 166); sizing comes from state.config.
        let rects = SlotGeometry.rects(cols: state.cols, emphasis: state.emphasis,
                                       focusSlot: state.focusSlot, in: vis, config: state.config)
        let centerY = SlotGeometry.centerY(in: vis)

        return state.ring.map { id in
            let pinnedSlot = r.pins.first(where: { $0.value == id })?.key
            var frame = CGRect.zero
            var inSlot: Slot? = nil
            var parked = false

            if let ps = pinnedSlot, let rect = rects[ps] {
                frame = rect
                inSlot = ps
            } else {
                let up = r.unpinned.firstIndex(of: id) ?? 0
                var d = posMod(up - r.centerPos, r.m)
                if Double(d) > Double(r.m) / 2 { d -= r.m }
                let t = r.anchorIdx + d
                if t >= 0, t < r.unpinnedSlots.count, let rect = rects[r.unpinnedSlots[t]] {
                    frame = rect
                    inSlot = r.unpinnedSlots[t]
                } else {
                    parked = true
                    frame = parkedFrame(t: t, resolved: r, rects: rects, vis: vis, centerY: centerY)
                }
            }

            let active = inSlot != nil && inSlot == r.focusSlot
            return WindowPlacement(id: id, frame: frame, active: active, parked: parked, slot: inSlot)
        }
    }

    /// A parked window is pushed entirely off the nearest edge so it can later slide back in.
    /// Sized like the end slot it parks behind (prototype parks behind the first/last slot).
    private func parkedFrame(t: Int, resolved r: Resolved, rects: [Slot: CGRect],
                             vis: CGRect, centerY: CGFloat) -> CGRect {
        let dir: CGFloat = t < 0 ? -1 : 1
        let endSlot = t < 0 ? r.unpinnedSlots.first : r.unpinnedSlots.last
        let size = endSlot.flatMap { rects[$0] }?.size
            ?? CGSize(width: vis.width * 0.2, height: vis.height * 0.6)
        let x = dir < 0 ? vis.minX - size.width - Self.parkGap : vis.maxX + Self.parkGap
        return CGRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)
    }
}

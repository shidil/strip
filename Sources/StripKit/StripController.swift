import AppKit

/// Owns the live strip: tracks the managed windows, holds the `StripState`, and applies the layout
/// engine's placements to real windows via the Accessibility API. M1 applies frames instantly
/// (no animation yet — that's M2).
public final class StripController {
    private let ax = AccessibilityService()
    private let animator = WindowAnimator()
    public private(set) var state: StripState
    private var windowsById: [CGWindowID: ManagedWindow] = [:]
    private var screen: NSScreen

    /// When true (M2+), frame changes spring smoothly; when false, they snap instantly.
    public var animated = true

    public init() {
        self.state = StripState(cols: 3, emphasis: .focus, focusSlot: .C)
        self.screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    public var managedCount: Int { state.ring.count }

    /// Swap the spring feel (M5 cycles this with the `t` key).
    public func setSpring(_ cfg: SpringConfig) { animator.config = cfg }

    // MARK: - Discovery

    /// Re-enumerate windows and reconcile them into the ring.
    ///
    /// Crucially, a window already in the strip stays managed as long as it still *exists* — even
    /// when we've parked it off-screen — so re-scanning never drops our own parked windows. The
    /// "is it on the active display" test only gates *new* windows joining the strip.
    public func refresh() {
        screen = activeScreen()
        let all = ax.allWindows()
        var allById: [CGWindowID: ManagedWindow] = [:]
        for w in all { allById[w.id] = w }

        // New-membership candidates: windows centered on the active display — PLUS any window
        // that's orphaned off every display (e.g. parked off-screen by a previous Strip that was
        // killed/crashed). Reclaiming orphans means a restart never strands windows off-screen.
        let screenRect = screen.quartzFrame
        let allScreenRects = NSScreen.screens.map { $0.quartzFrame }
        func belongsToActiveStrip(_ w: ManagedWindow) -> Bool {
            let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
            if screenRect.contains(c) { return true }
            return !allScreenRects.contains { $0.contains(c) } // orphan → reclaim
        }
        let newOnScreen = all
            .filter(belongsToActiveStrip)
            .sorted { $0.frame.minX < $1.frame.minX }

        var ring = state.ring.filter { allById[$0] != nil } // keep existing while they exist
        for w in newOnScreen where !ring.contains(w.id) { ring.append(w.id) }
        state.ring = ring

        windowsById = [:]
        for id in ring { windowsById[id] = allById[id] }

        if state.centerId == nil || !ring.contains(state.centerId!) {
            state.centerId = ring.first
        }
        normalize()
    }

    // MARK: - Layout commands (menu-driven in M1)

    public func setCols(_ n: Int) {
        state.cols = n
        // Keep only pins whose slot still exists; clamp focus to a valid slot.
        let keys = state.slots
        state.pins = state.pins.filter { keys.contains($0.key) }
        if !keys.contains(state.focusSlot) { state.focusSlot = state.primarySlot }
        normalize()
        apply()
    }

    public func setEmphasis(_ e: Emphasis) {
        state.emphasis = e
        apply()
    }

    public func toggleEmphasis() {
        setEmphasis(state.emphasis == .focus ? .equal : .focus)
    }

    private var springIndex = 0
    /// Cycle the animation feel (`t` key). Faithful stand-in for the prototype's film-feel cycling;
    /// real windows can only translate/resize, so we vary the spring rather than 3D transforms.
    public func cycleSpring() {
        springIndex = (springIndex + 1) % SpringConfig.presets.count
        let cfg = SpringConfig.presets[springIndex]
        setSpring(cfg)
        Log.line("spring feel: \(cfg.name)")
    }

    /// Slide the film: bring the previous/next window to center (`rotate`, prototype lines 334-340).
    public func rotate(_ dir: Int) {
        let pinned = Set(state.pins.values)
        let up = state.ring.filter { !pinned.contains($0) }
        guard !up.isEmpty else { return }
        let pos = state.centerId.flatMap { up.firstIndex(of: $0) } ?? 0
        state.centerId = up[posMod(pos + dir, up.count)]
        apply()
    }

    /// Move keyboard focus between slots (`focusMove`, prototype lines 348-354).
    public func focusMove(_ dir: Int) {
        let up = state.slots.filter { state.pins[$0] == nil }
        guard !up.isEmpty else { return }
        let i = up.firstIndex(of: state.focusSlot) ?? 0
        let ni = min(max(0, i + dir), up.count - 1)
        state.focusSlot = up[ni]
        apply()
    }

    /// Carry the centered window along the film, reordering it (`moveWindow`, prototype lines 341-347).
    public func moveWindow(_ dir: Int) {
        guard let center = state.centerId, let i = state.ring.firstIndex(of: center) else { return }
        let j = posMod(i + dir, state.ring.count)
        state.ring.swapAt(i, j)
        apply()
    }

    // MARK: - Apply to real windows

    /// Compute placements and move every managed window to its target frame — springing smoothly
    /// when `animated`, snapping instantly otherwise.
    public func apply() {
        guard !state.ring.isEmpty else { return }
        let vis = screen.quartzVisibleFrame
        let layout = StripLayout(state)
        let placements = layout.placements(in: vis)

        let targets: [(ax: AXWindow, frame: CGRect)] = placements.compactMap { p in
            windowsById[p.id].map { (ax: $0.ax, frame: p.frame) }
        }
        if animated {
            animator.animate(targets, on: screen)
        } else {
            animator.snap(targets)
        }
        if let activeId = layout.activeId, let w = windowsById[activeId] {
            w.ax.raise()
        }
        logState(placements)
    }

    public func refreshAndApply() {
        refresh()
        apply()
    }

    // MARK: - Helpers

    private func normalize() {
        if !state.slots.contains(state.focusSlot) { state.focusSlot = state.primarySlot }
        state.pins = state.pins.filter { state.slots.contains($0.key) }
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
            ?? screen
    }

    private func logState(_ placements: [WindowPlacement]) {
        let layout = state.cols == 1 ? "monocle" : "\(state.cols)-up · \(state.emphasis == .focus ? "focus" : "equal")"
        Log.line("apply: \(layout) on \(screen.localizedName) — \(placements.filter { !$0.parked }.count) slotted, \(placements.filter { $0.parked }.count) parked")
        for p in placements {
            let name = windowsById[p.id]?.appName ?? "?"
            let where_ = p.parked ? "PARKED" : (p.slot.map { $0.rawValue } ?? "?")
            let mark = p.active ? "◀focus" : ""
            Log.line(String(format: "   %@ %-16@ slot=%-6@ frame=(%.0f,%.0f %.0fx%.0f) %@",
                            p.active ? "●" : "·", name as NSString, where_ as NSString,
                            p.frame.origin.x, p.frame.origin.y, p.frame.width, p.frame.height, mark))
        }
    }
}

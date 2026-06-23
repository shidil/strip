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
    /// The window we last handed keyboard focus to — so `apply()` only re-focuses on a real change.
    private var lastFocusedId: CGWindowID?

    /// When true (M2+), frame changes spring smoothly; when false, they snap instantly.
    public var animated = true

    /// Emitted after every `apply()` so the overlay chrome (M4 film rail, etc.) can re-render.
    public var onRender: ((OverlaySnapshot) -> Void)?

    /// Emitted with the focused window's live frame (Quartz global) so the overlay can track it with
    /// a focus ring as it animates; `nil` hides the ring.
    public var onFocusFrame: ((CGRect?) -> Void)?

    public init() {
        self.state = StripState(cols: 3, emphasis: .focus, focusSlot: .C)
        self.screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        animator.onFocusFrame = { [weak self] frame in self?.onFocusFrame?(frame) }
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

    /// Pin/unpin the focused slot (⌃⌥P). The engine already honors `state.pins`; the state mutation
    /// lives in `StripState.togglePin()` — here we just re-apply so pinned windows hold while the
    /// rest of the film flows.
    public func togglePin() {
        state.togglePin()
        apply()
    }

    /// Bring a specific window to center (film-rail chip click; `StripState.setCenter`).
    public func setCenter(_ id: CGWindowID) {
        state.setCenter(id)
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
        animator.focusedID = layout.activeId // ring tracks the focused window
        if animated {
            animator.animate(targets, on: screen)
        } else {
            animator.snap(targets)
        }
        // Move real keyboard focus to the focused-slot window, but only when it actually changes —
        // so re-applies that don't change focus (spring cycle, re-tile) don't yank the keyboard around.
        if let activeId = layout.activeId, let w = windowsById[activeId], activeId != lastFocusedId {
            w.ax.focus()
            lastFocusedId = activeId
        }
        logState(placements)
        onRender?(railSnapshot(layout))
    }

    /// Build the overlay snapshot from the current state + layout (mirrors prototype `rail` +
    /// the status-bar labels, lines 269-293).
    private func railSnapshot(_ layout: StripLayout) -> OverlaySnapshot {
        let assigned = Set(layout.assignment().values)
        let activeId = layout.activeId
        let pinned = Set(state.pins.values)
        let items = state.ring.compactMap { id -> RailItem? in
            guard let w = windowsById[id] else { return nil }
            return RailItem(id: id, letter: w.letter, accent: w.accent,
                            assigned: assigned.contains(id), active: id == activeId,
                            pinned: pinned.contains(id))
        }

        let activeApp = activeId.flatMap { windowsById[$0]?.appName } ?? "—"
        let activeAccent = activeId.flatMap { windowsById[$0]?.accent }
        let layoutLabel = state.cols == 1
            ? "Monocle"
            : "\(state.cols)‑up · \(state.emphasis == .focus ? "focus" : "equal")"
        let pc = state.pins.count
        let modeLabel = pc == 0 ? "Strip shift" : (pc >= state.slots.count ? "Independent" : "Hybrid")

        return OverlaySnapshot(rail: items, screen: screen, activeApp: activeApp,
                               activeAccent: activeAccent, layoutLabel: layoutLabel,
                               modeLabel: modeLabel, transLabel: animator.config.name,
                               clock: Self.clock())
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()
    private static func clock() -> String { clockFormatter.string(from: Date()) }

    public func refreshAndApply() {
        refresh()
        apply()
    }

    // MARK: - Helpers

    private func normalize() {
        state.clampToValidSlots()
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
        let pins = state.pins.isEmpty
            ? ""
            : " — pinned " + state.pins.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue):\(windowsById[$0.value]?.appName ?? "?")" }
                .joined(separator: ",")
        Log.line("apply: \(layout) on \(screen.localizedName) — \(placements.filter { !$0.parked }.count) slotted, \(placements.filter { $0.parked }.count) parked\(pins)")
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

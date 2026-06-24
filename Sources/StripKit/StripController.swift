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

    /// Release-all escape hatch (M7): while suspended, Strip stops driving windows entirely —
    /// `refresh()`/`apply()` no-op so debounced auto-react events are ignored and windows stay
    /// exactly where the user left them. Toggled by ⌃⌥0 (or resumed by any explicit command).
    public private(set) var isSuspended = false

    /// Emitted after every `apply()` so the overlay chrome (M4 film rail, etc.) can re-render.
    public var onRender: ((OverlaySnapshot) -> Void)?

    /// Emitted with the focused window's live frame (Quartz global) so the overlay can track it with
    /// a focus ring as it animates; `nil` hides the ring.
    public var onFocusFrame: ((CGRect?) -> Void)?

    /// Whether the focus ring (the border drawn around the focused window) is shown. Toggled from the
    /// status-bar menu and persisted. When `false` we forward `nil` frames so the overlay hides the
    /// ring at its source — the animator keeps reporting frames, we just swallow them.
    public private(set) var focusRingEnabled = true

    public init() {
        self.state = StripState(cols: 3, emphasis: .focus, focusSlot: .C)
        self.screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        animator.onFocusFrame = { [weak self] frame in
            guard let self else { return }
            self.onFocusFrame?(self.focusRingEnabled ? frame : nil)
        }
        animator.onWindowLost = { [weak self] id in self?.dropLostWindow(id) }
        restoreSettings()
    }

    // MARK: - Persistence

    /// Restore the saved sizing knobs and layout posture (window identity is re-discovered, not saved).
    private func restoreSettings() {
        guard let s = PersistedSettings.load() else { return }
        state.config = s.config
        state.cols = s.cols
        state.emphasis = s.emphasisEqual ? .equal : .focus
        state.clampToValidSlots()
        if SpringConfig.presets.indices.contains(s.springIndex) {
            springIndex = s.springIndex
            animator.config = SpringConfig.presets[springIndex]
        }
        focusRingEnabled = s.focusRingEnabled
        Log.line("restored settings: \(state.cols)-up, focusRatio \(String(format: "%.2f", state.config.focusRatio)), height \(String(format: "%.2f", state.config.heightFraction)), ring \(focusRingEnabled ? "on" : "off")")
    }

    /// Persist the current sizing knobs and layout posture.
    private func persist() {
        PersistedSettings(config: state.config, cols: state.cols,
                          emphasisEqual: state.emphasis == .equal, springIndex: springIndex,
                          focusRingEnabled: focusRingEnabled).save()
    }

    /// Show or hide the focus ring (status-bar toggle). Persists, then refreshes the overlay
    /// immediately: re-emitting the focused window's current frame turns it back on, while `nil`
    /// hides it — neither touches managed windows.
    public func setFocusRing(_ enabled: Bool) {
        guard enabled != focusRingEnabled else { return }
        focusRingEnabled = enabled
        Log.line("focus ring: \(enabled ? "on" : "off")")
        persist()
        if enabled {
            animator.reemitFocusFrame()
        } else {
            onFocusFrame?(nil)
        }
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
        guard !isSuspended else { return }
        screen = activeScreen()
        let all = ax.allWindows()
        var allById: [CGWindowID: ManagedWindow] = [:]
        for w in all { allById[w.id] = w }

        // Transient-miss resilience (M7): AX enumeration is flaky during app activation churn — a
        // busy app can return an incomplete window list for one scan, especially right after we
        // activate a window on `apply()`. A ring window absent from *this* scan but whose AX element
        // is still alive is just such a miss, not a closed window; keep it (reusing its still-valid
        // handle, refreshing its live frame) so it isn't wrongly dropped and stranded out of the
        // strip. Only a genuinely-dead element falls through to be dropped below.
        for id in state.ring where allById[id] == nil {
            guard var w = windowsById[id], w.ax.isAlive else { continue }
            if let live = w.ax.frame { w.frame = live }
            allById[id] = w
        }

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

        // Was the strip already populated? If so, windows appearing now are *genuinely new* (an app
        // opened a window while Strip runs) and get the new-window placement treatment. On the very
        // first scan (or after the strip emptied) we just lay everything out in on-screen order
        // without yanking focus around.
        let oldState = state
        let wasPopulated = !state.ring.isEmpty
        let kept = state.ring.filter { allById[$0] != nil } // keep existing while they exist
        let known = Set(kept)
        state.ring = kept

        let appeared = newOnScreen.filter { !known.contains($0.id) }
        if wasPopulated {
            for w in appeared { state.insertManaged(w.id, placement: state.config.newWindowPlacement) }
        } else {
            for w in appeared { state.ring.append(w.id) }
        }

        // If the centered window vanished (e.g. you closed it) and no newly-opened window claimed the
        // center, hand the center to its on-screen neighbor — the window that was to its left, else
        // its right — so closing the focused window returns you to your previous context rather than
        // snapping to the start of the film.
        if state.centerId == nil || !state.ring.contains(state.centerId!) {
            state.centerId = Self.neighborOfClosedCenter(in: oldState, survivors: Set(state.ring))
                ?? state.ring.first
        }

        windowsById = [:]
        for id in state.ring { windowsById[id] = allById[id] }
        normalize()
    }

    /// When the centered window is gone, pick its replacement from the windows that flanked it: the
    /// one that was in the slot to its left, then to its right, expanding outward. Pure (operates on
    /// the pre-reconcile `old` state + the set of `survivors`), so it's unit-testable. Returns nil if
    /// no flanking window survives — the caller then falls back to the start of the film.
    static func neighborOfClosedCenter(in old: StripState, survivors: Set<CGWindowID>) -> CGWindowID? {
        guard let removed = old.centerId else { return nil }
        let assign = StripLayout(old).assignment()
        guard let anchorSlot = assign.first(where: { $0.value == removed })?.key,
              let anchorIdx = old.slots.firstIndex(of: anchorSlot) else { return nil }

        // Visit slots outward from the anchor: immediate left, immediate right, then further out.
        var order: [Slot] = []
        var l = anchorIdx - 1, r = anchorIdx + 1
        while l >= 0 || r < old.slots.count {
            if l >= 0 { order.append(old.slots[l]); l -= 1 }
            if r < old.slots.count { order.append(old.slots[r]); r += 1 }
        }
        for s in order {
            if let id = assign[s], id != removed, survivors.contains(id) { return id }
        }
        return nil
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
        persist()
    }

    public func setEmphasis(_ e: Emphasis) {
        state.emphasis = e
        apply()
        persist()
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
        persist()
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

    /// Live window-sizing knobs (⌃⌥-/= widen/narrow the focus window; ⌃⌥[ /] tighten/loosen gaps).

    /// Widen/narrow the dominant window by `delta`. In monocle this grows the centered window toward
    /// a filled screen; in 2-/3-up it shifts the focus window's width share. Both clamped.
    public func adjustFocusRatio(_ delta: CGFloat) {
        if state.cols == 1 {
            state.config.monocleWidthFraction += delta
            state.config.monocleWidthFraction = state.config.clampedMonocleWidth
            Log.line("monocle width: \(String(format: "%.2f", state.config.monocleWidthFraction))")
        } else {
            state.config.focusRatio += delta
            state.config.focusRatio = state.config.clampedFocusRatio
            Log.line("focus ratio: \(String(format: "%.2f", state.config.focusRatio))")
        }
        apply()
        persist()
    }

    /// Grow/shrink every window's height by `delta` (clamped to `LayoutConfig.heightRange`); windows
    /// stay vertically centered, gaining margin top and bottom as they shrink.
    public func adjustHeight(_ delta: CGFloat) {
        state.config.heightFraction += delta
        state.config.heightFraction = state.config.clampedHeight
        Log.line("height: \(String(format: "%.2f", state.config.heightFraction))")
        apply()
        persist()
    }

    /// Nudge the inter-window gap and outer padding together by `delta` (floored at 0).
    public func adjustGap(_ delta: CGFloat) {
        state.config.innerGap = max(0, state.config.innerGap + delta)
        state.config.outerPadding = max(0, state.config.outerPadding + delta)
        Log.line("gap: \(Int(state.config.innerGap)) pad: \(Int(state.config.outerPadding))")
        apply()
        persist()
    }

    // MARK: - Apply to real windows

    /// Compute placements and move every managed window to its target frame — springing smoothly
    /// when `animated`, snapping instantly otherwise.
    public func apply() {
        guard !isSuspended, !state.ring.isEmpty else { return }
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
            let aspect = w.frame.height > 0 ? w.frame.width / w.frame.height : 1.6
            return RailItem(id: id, letter: w.letter, appName: w.appName, title: w.title,
                            accent: w.accent, assigned: assigned.contains(id),
                            active: id == activeId, pinned: pinned.contains(id), aspect: aspect)
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

    // MARK: - Respect user drags (M7 Slice 4)

    /// Whether the animator is currently driving `id` — the window observer consults this so the
    /// `AXMoved`/`AXResized` our own frame writes generate don't read as user drags.
    public func isDriving(_ id: CGWindowID) -> Bool { animator.isDriving(id) }

    /// Handle a finished user drag of window `id` (the window observer has already debounced to the
    /// trailing edge and confirmed it wasn't our own write).
    ///
    /// Policy (locked): a **move** of any tiled window, or a **resize of a non-dominant** window,
    /// snaps back to its slot — re-absorbing keeps the strip coherent. A **resize of the dominant
    /// (emphasized) window** is *kept* by mapping its new frame into the sizing knobs (width →
    /// `focusRatio`/`monocleWidthFraction`, height → `heightFraction`) so the whole strip
    /// re-proportions — honoring the resize fights macOS less than yanking it back.
    ///
    /// Either way the window physically moved behind the animator's back, so its `spring.current` is
    /// stale; we `forget` it before re-applying so it glides from where the user left it rather than
    /// no-op'ing (move) or jumping from its old slot first (resize) — the Slice-1 lesson.
    public func handleUserDrag(id: CGWindowID, wasResize: Bool) {
        guard !isSuspended, state.ring.contains(id), let w = windowsById[id] else { return }

        if wasResize, id == dominantWindowId(), let live = w.ax.frame {
            let vis = screen.quartzVisibleFrame
            state.config = DragResolver.resizeConfig(focusFrame: live, vis: vis, cols: state.cols,
                                                     emphasis: state.emphasis, base: state.config)
            Log.line("user-resize kept: focusRatio \(String(format: "%.2f", state.config.focusRatio)), monocle \(String(format: "%.2f", state.config.monocleWidthFraction)), height \(String(format: "%.2f", state.config.heightFraction))")
            persist()
        } else {
            Log.line("user-drag: window \(id) snapped back to slot")
        }

        // Return crisply (snap-back spring), gliding from where the user let go (forget → re-seat
        // from the live frame) rather than no-op'ing on a stale spring. Terminal-class windows snap
        // straight to their target instead of springing — springing makes them re-quantize their
        // character-cell size every frame (a visible staircase); one write avoids it.
        animator.forget(id)
        animator.requestSnapBack()
        animator.snapNext(steppingWindowIds())
        apply()
    }

    /// Ring windows whose app quantizes its size on resize (terminals) — they snap rather than spring.
    private func steppingWindowIds() -> Set<CGWindowID> {
        Set(state.ring.filter { id in
            guard let w = windowsById[id] else { return false }
            return SteppingApps.isStepping(key: w.accentKey, appName: w.appName)
        })
    }

    /// The window whose width the size knobs govern — the emphasized slot's occupant: `.C` in monocle
    /// and 3-up, the focused slot in 2-up (mirrors `SlotGeometry`'s emphasized-slot choice).
    private func dominantWindowId() -> CGWindowID? {
        let emphasized: Slot = state.cols == 2 ? state.focusSlot : .C
        return StripLayout(state).assignment()[emphasized]
    }

    // MARK: - Release / suspend (M7 escape hatch)

    /// Toggle the release-all escape hatch (⌃⌥0). When engaging, un-park every managed window that
    /// has been pushed off-screen back onto sane on-screen frames, then **suspend** management so
    /// auto-react stops touching windows — an explicit "let go." Toggling again (or any explicit
    /// command, via `resumeIfSuspended()`) resumes and re-tiles.
    public func releaseAll() {
        if isSuspended { resume(); return }

        screen = activeScreen()
        let n = unparkStranded(in: screen.quartzVisibleFrame)
        isSuspended = true
        Log.line("release-all: un-parked \(n) window(s), management SUSPENDED (⌃⌥0 to resume)")
    }

    /// Move every managed window that's currently parked off the visible area back onto a sane
    /// on-screen frame, **synchronously on the main thread**. Called from `applicationWillTerminate`
    /// so quitting Strip (today only the *next* launch reclaims orphans) never leaves a window
    /// stranded off the display edge. Hard crashes can't run code; those still rely on the next
    /// launch's orphan-reclaim in `refresh()`.
    public func unparkAllOnScreen() {
        let n = unparkStranded(in: activeScreen().quartzVisibleFrame)
        if n > 0 { Log.line("quit: un-parked \(n) window(s) back on-screen") }
    }

    /// Drop a window the animator reported dead (AX writes failing — stale element after an app
    /// relaunch/crash) so it stops occupying a slot and wedging re-tiles. If it was the centered
    /// window, hand the center to a surviving neighbor (same rule as closing the centered window);
    /// pins on it are cleared. Re-applies so the strip closes the gap. (M7 AX-drop recovery.)
    private func dropLostWindow(_ id: CGWindowID) {
        guard state.ring.contains(id) else { return }
        let old = state
        state.ring.removeAll { $0 == id }
        windowsById[id] = nil
        state.pins = state.pins.filter { $0.value != id }
        if state.centerId == id {
            state.centerId = Self.neighborOfClosedCenter(in: old, survivors: Set(state.ring))
                ?? state.ring.first
        }
        state.clampToValidSlots()
        Log.line("ax-drop: window \(id) dead (AX writes failing) — dropped from strip")
        apply()
    }

    /// Find every managed window whose center sits outside `vis` (parked off-screen) and write it
    /// back to a centered, cascaded on-screen frame via direct AX (no animator — used by the
    /// release escape hatch and quit-safety, neither of which can rely on the display link ticking).
    /// On-screen windows are left exactly where they are. Returns how many were rescued.
    @discardableResult
    private func unparkStranded(in vis: CGRect) -> Int {
        let stranded = state.ring.compactMap { id -> AXWindow? in
            guard let w = windowsById[id] else { return nil }
            let f = w.ax.frame ?? w.frame
            return vis.contains(CGPoint(x: f.midX, y: f.midY)) ? nil : w.ax
        }
        for (i, ax) in stranded.enumerated() {
            let frame = Self.unparkFrame(index: i, of: stranded.count, in: vis)
            EnhancedUI.suppressed(on: AXUIElementCreateApplication(ax.pid)) { ax.setFrame(frame) }
        }
        return stranded.count
    }

    /// Resume management after a release and re-tile immediately.
    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        // Drop the animator's cached spring positions so every window re-seats from where it
        // actually sits now (you may have dragged things around while released) and visibly springs
        // back into the strip — otherwise the animator stays "settled" and nothing moves.
        animator.reset()
        Log.line("release-all: management RESUMED")
        refreshAndApply()
    }

    /// Resume if currently suspended; a no-op otherwise. Called when the user issues an explicit
    /// layout/navigation command so they don't have to press ⌃⌥0 first.
    public func resumeIfSuspended() {
        if isSuspended { resume() }
    }

    /// On-screen frame for a window being un-parked/released. Centered at a comfortable size, then
    /// cascaded by `index` so several released windows don't land in a perfect stack. Pure (only
    /// `CGRect` math) so the geometry is unit-testable without AppKit/AX.
    static func unparkFrame(index: Int, of count: Int, in vis: CGRect) -> CGRect {
        let size = CGSize(width: vis.width * 0.6, height: vis.height * 0.7)
        let originX = vis.minX + (vis.width - size.width) / 2
        let originY = vis.minY + (vis.height - size.height) / 2
        // Cascade down-right within the slack between the centered window and the visible edges,
        // wrapping so the offset never pushes the window off-screen no matter how many are released.
        // The window starts centered, so only *half* the slack is available below/right of it.
        let step: CGFloat = 36
        let slackX = max(0, vis.width - size.width) / 2
        let slackY = max(0, vis.height - size.height) / 2
        let span = max(1, Int(min(slackX, slackY) / step))
        let k = CGFloat(count > 1 ? index % span : 0)
        return CGRect(x: originX + k * step, y: originY + k * step, width: size.width, height: size.height)
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

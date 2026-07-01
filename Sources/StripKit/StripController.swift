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

    /// Set while a coalesced `apply()` is already queued for the next run-loop pass — so a burst of
    /// rapid commands (a held/auto-repeating slide key) collapses into one apply, not one per repeat.
    /// See `scheduleApply()`.
    private var applyScheduled = false

    /// The pending debounced keyboard-focus hand-off (see `scheduleFocus(_:_:)`); cancelled and
    /// rescheduled on each slide so only the window you finally land on gets focused.
    private var focusWork: DispatchWorkItem?

    /// How long sliding must be idle before keyboard focus actually moves. `focus()` is 3 synchronous
    /// cross-process AX calls + `activate()` (~20ms for Electron apps); debouncing it keeps that off
    /// the per-frame slide path so the display-link tick never starves. Kept a touch longer than
    /// `minNavInterval` so a held scroll only activates the window you finally land on, not every
    /// window it passes. Imperceptible for single taps.
    private static let focusSettleDelay: TimeInterval = 0.17

    /// Paced-navigation state (held slide / focus-move). A held key auto-repeats at ~30/s — far faster
    /// than the springs can carry a window across a slot — so advancing the ring on every repeat leaves
    /// every window stuck mid-flight, bunched around the center. We instead advance at most once per
    /// `minNavInterval`, giving each step time to travel; surplus repeats are dropped. Fresh presses
    /// (not auto-repeats) bypass this entirely for 1:1 tap responsiveness.
    private var navWork: DispatchWorkItem?
    private var pendingNav: (() -> Void)?
    private var lastNavAt = Date.distantPast
    /// One slide step per 200ms ≈ 5 windows/s — a calm, watchable film scroll. Tune to taste:
    /// lower = faster scroll but more clustering; higher = cleaner but more sluggish.
    private static let minNavInterval: TimeInterval = 0.20

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

    /// Emitted with an app's pid just before `apply()` activates it to move keyboard focus, so the
    /// window observer can ignore the activation/focus notifications that activation generates instead
    /// of treating them as a real change and forcing a redundant reconcile (perf 1.1).
    public var onWillActivate: ((pid_t) -> Void)?

    /// Whether the focus ring (the border drawn around the focused window) is shown. Toggled from the
    /// status-bar menu and persisted. When `false` we forward `nil` frames so the overlay hides the
    /// ring at its source — the animator keeps reporting frames, we just swallow them.
    public private(set) var focusRingEnabled = true
    /// Which screen edge the film rail (minimap) is anchored to. Toggled from the status-bar menu
    /// and persisted, exactly like `focusRingEnabled`.
    public private(set) var railEdge: RailEdge = .default

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
        railEdge = s.railEdge
        Log.line("restored settings: \(state.cols)-up, focusRatio \(String(format: "%.2f", state.config.focusRatio)), height \(String(format: "%.2f", state.config.heightFraction)), ring \(focusRingEnabled ? "on" : "off"), rail \(railEdge.rawValue)")
    }

    /// Persist the current sizing knobs and layout posture.
    private func persist() {
        PersistedSettings(config: state.config, cols: state.cols,
                          emphasisEqual: state.emphasis == .equal, springIndex: springIndex,
                          focusRingEnabled: focusRingEnabled, railEdge: railEdge).save()
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

    /// Move the film rail to a different screen edge (status-bar toggle). Persists, then re-applies
    /// so a fresh `OverlaySnapshot` carrying the new edge is emitted — the edge itself doesn't affect
    /// window tiling, so this is the same harmless/idempotent re-apply "Re-tile" already performs.
    public func setRailEdge(_ edge: RailEdge) {
        guard edge != railEdge else { return }
        railEdge = edge
        Log.line("rail edge: \(edge.rawValue)")
        persist()
        apply()
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
        let sp = Signpost.log
        let refreshState = sp.beginInterval("refresh")
        defer { sp.endInterval("refresh", refreshState) }

        screen = activeScreen()
        let all = ax.allWindows()
        var allById: [CGWindowID: ManagedWindow] = [:]
        for w in all { allById[w.id] = w }

        // Transient-miss resilience (M7): AX enumeration is flaky during app activation churn — a
        // busy app can return an incomplete window list for one scan, especially right after we
        // activate a window on `apply()`. A ring window absent from *this* scan that's still real is
        // just such a miss, not a closed window; keep it (reusing its still-valid handle, refreshing
        // its live frame) so it isn't wrongly dropped and stranded out of the strip. "Still real"
        // requires BOTH a live AX element AND the window server still showing it *on screen* — a
        // stale element whose id is gone (ghost), or a window that minimized/hid off the screen, is
        // not on-screen and falls through to be dropped below (see `keepsMissingWindow`).
        let onScreenIDs = ax.onScreenWindowIDs()
        for id in state.ring where allById[id] == nil {
            guard var w = windowsById[id],
                  Self.keepsMissingWindow(elementAlive: w.ax.isAlive,
                                          windowServerOnScreen: onScreenIDs.contains(id),
                                          isMinimized: w.ax.isMinimized)
            else { continue }
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

        // Float intrinsically-small newly-appeared windows (DMG installers, palettes): tiling one
        // would demote the focused window and reflow the strip (BUGS.md #4). Skipped windows never
        // enter the ring, so Strip never moves them; the check is re-applied each scan, so one that
        // later grows past the threshold is admitted automatically.
        let vis = screen.quartzVisibleFrame
        let appeared = newOnScreen.filter {
            !known.contains($0.id) && Self.isTileableSize($0.frame.size, onDisplay: vis)
        }
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

    /// Decide whether a ring window that's *absent from the current AX enumeration* is a transient
    /// miss to keep, or one to drop. Pure, so it's unit-testable.
    ///
    /// AX `kAXWindows` enumeration is flaky during app-activation churn, so absence alone never means
    /// the window is gone. We keep it only when all three say it's a real, on-strip window:
    /// - `elementAlive` — the AX element isn't destroyed, AND
    /// - `windowServerOnScreen` — the window server still shows it on screen, AND
    /// - `!isMinimized` — it isn't minimized to the Dock.
    ///
    /// Relying on `elementAlive` alone was the ghost bug — some apps leave the AX element answering
    /// (`.cannotComplete`, not `.invalidUIElement`) after their window closes, so the entry parked
    /// off-screen forever; the window-server's on-screen list is authoritative and clears that.
    /// `windowServerOnScreen` (the on-screen list, not the full `.optionAll` list) also fixes the
    /// minimize/hide gap: an app that closes its window to the Dock (e.g. Slack) leaves the window
    /// alive and still in the full window list — and *not* flagged minimized — so it lingered, holding
    /// a slot over empty wallpaper. Once it's off the screen it's dropped and the strip closes up;
    /// reopening posts a reconcile (WindowObserver) that re-admits it as a fresh window. The explicit
    /// `isMinimized` gate is kept as defense-in-depth for the case an app reports a minimized window
    /// as still on-screen.
    static func keepsMissingWindow(elementAlive: Bool, windowServerOnScreen: Bool, isMinimized: Bool) -> Bool {
        elementAlive && windowServerOnScreen && !isMinimized
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

    /// A newly-appeared window narrower/shorter than these fractions of the display's visible area is
    /// treated as a transient/utility window (DMG installer, palette) and left floating instead of
    /// tiled — tiling it would demote the focused window and reflow the strip (BUGS.md #4). Tunable.
    static let minTileWidthFraction: CGFloat = 0.2
    static let minTileHeightFraction: CGFloat = 0.4

    /// Whether a newly-appeared window is large enough to auto-tile. Floats (returns false) when EITHER
    /// dimension is below its fraction of the visible frame. Only gates NEW windows — an already-managed
    /// window later resized small stays managed (ring membership is sticky). Pure → unit-testable.
    static func isTileableSize(_ size: CGSize, onDisplay vis: CGRect) -> Bool {
        size.width >= vis.width * minTileWidthFraction && size.height >= vis.height * minTileHeightFraction
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
    /// A held key (`repeated`) is paced so the film scrolls at a watchable rate; a fresh press acts now.
    public func rotate(_ dir: Int, repeated: Bool = false) {
        navStep(repeated) { [weak self] in self?.advanceCenter(dir) }
    }

    private func advanceCenter(_ dir: Int) {
        let pinned = Set(state.pins.values)
        let up = state.ring.filter { !pinned.contains($0) }
        guard !up.isEmpty else { return }
        let pos = state.centerId.flatMap { up.firstIndex(of: $0) } ?? 0
        state.centerId = up[posMod(pos + dir, up.count)]
    }

    /// Run a navigation step now (fresh press → 1:1 responsive) or paced (held key → at most one step
    /// per `minNavInterval`, latest direction wins, surplus repeats dropped). Either way the expensive
    /// window-moving `apply()` is coalesced via `scheduleApply()`.
    private func navStep(_ repeated: Bool, _ step: @escaping () -> Void) {
        guard repeated else {
            lastNavAt = Date()
            step()
            scheduleApply()
            return
        }
        pendingNav = step
        guard navWork == nil else { return } // a paced step is already queued; this one's `step` wins
        let delay = max(0, Self.minNavInterval - Date().timeIntervalSince(lastNavAt))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.navWork = nil
            guard let step = self.pendingNav else { return }
            self.pendingNav = nil
            self.lastNavAt = Date()
            step()
            self.scheduleApply()
        }
        navWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Move keyboard focus between slots (`focusMove`, prototype lines 348-354).
    public func focusMove(_ dir: Int, repeated: Bool = false) {
        navStep(repeated) { [weak self] in self?.advanceFocus(dir) }
    }

    private func advanceFocus(_ dir: Int) {
        state.focusSlot = state.focusSlotAfterMove(dir)
    }

    /// Carry the *focused* window along the film, reordering it (`moveFocused`, prototype lines
    /// 341-347) — the state transition lives in `StripState.moveFocused` (pure, unit-tested); this
    /// just re-applies so the reordered film re-tiles.
    public func moveFocused(_ dir: Int) {
        state.moveFocused(dir)
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
        let sp = Signpost.log
        let applyState = sp.beginInterval("apply")
        defer { sp.endInterval("apply", applyState) }

        let vis = screen.quartzVisibleFrame
        let layout = StripLayout(state)
        // Nested interval: isolates pure layout-recompute time within the command path. Measured at
        // the call site so the engine (StripLayout) stays os-free and trivially unit-testable.
        let placementsState = sp.beginInterval("placements")
        let placements = layout.placements(in: vis)
        sp.endInterval("placements", placementsState)

        // `current` is the window's live frame (read during the last `refresh()`), passed so the
        // animator can seed a new window's spring without its own synchronous AX read (perf: animate
        // seeding). It's only consumed when the animator has no existing entry for the window; for the
        // user-drag re-seat, `handleUserDrag` refreshes this cached frame to where the user left it.
        let targets: [(ax: AXWindow, frame: CGRect, current: CGRect)] = placements.compactMap { p in
            windowsById[p.id].map { (ax: $0.ax, frame: p.frame, current: $0.frame) }
        }
        animator.focusedID = layout.activeId // ring tracks the focused window
        if animated {
            animator.animate(targets, on: screen)
        } else {
            animator.snap(targets)
        }
        // Move real keyboard focus to the focused-slot window, but only when it actually changes —
        // so re-applies that don't change focus (spring cycle, re-tile) don't yank the keyboard around.
        // Debounced off the hot path: focus() is synchronous cross-process AX, too costly to run on
        // every step of a fast slide (perf: slide stutter) — see scheduleFocus.
        if let activeId = layout.activeId, let w = windowsById[activeId], activeId != lastFocusedId {
            scheduleFocus(activeId, w)
        }
        logState(placements)
        onRender?(railSnapshot(layout))
    }

    /// Coalesce a burst of rapid commands (a held / auto-repeating slide key) into a single `apply()`
    /// per run-loop pass. The cheap state change (centerId / focusSlot) already happened synchronously
    /// at the call site, so the deferred apply always reflects the latest state. Without this, holding
    /// ⌃⌥L floods the main queue with one full apply per OS key-repeat — each a 20–49ms block that
    /// starves the `.main` display-link tick, so the springs never advance and the animation freezes.
    /// Coalesced, the spring simply re-targets one window further each repeat and glides continuously.
    private func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyScheduled = false
            self.apply()
        }
    }

    /// Hand real keyboard focus to the centered window — DEBOUNCED, and the AX itself dispatched OFF
    /// the main thread. Two compounding problems made fast slides stutter and a held slide key freeze:
    /// (1) `focus()` is synchronous cross-process AX (~20ms for an Electron app), and the centered
    /// window changes on every slide, so it ran on the main thread every step and starved the
    /// `.main` display-link tick; (2) it ran once per key-repeat. The debounce cancels on each new
    /// slide so only the window you finally settle on is focused; `animator.focus` then performs the
    /// AX on the app's serial queue, never on main. The *visual* focus ring still tracks immediately
    /// (animator.focusedID / emitFocusFrame) — only the OS focus routing is deferred + off-loaded.
    private func scheduleFocus(_ id: CGWindowID, _ w: ManagedWindow) {
        focusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Tell the observer we're about to activate this app, so the activation/focus
            // notifications our own focus() generates don't trigger a redundant reconcile (perf 1.1).
            // Set on main *before* the off-main activation lands; the 0.2s grace covers the hop.
            self.onWillActivate?(w.ax.pid)
            self.lastFocusedId = id
            self.animator.focusAttributes(w.ax) // cross-process AX off-main (the ~20ms part)
            w.ax.activateApp()                  // AppKit app-activation stays on main (cheap, ~1–2ms)
        }
        focusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusSettleDelay, execute: work)
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
                            accent: w.accent, icon: w.icon, assigned: assigned.contains(id),
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
                               clock: Self.clock(), railEdge: railEdge)
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

    /// Handle a pure external focus/activation (Cmd-Tab / `open -a` of a running app) of `pid` whose
    /// now-focused window is `focusedWindowID` (read cheaply by the observer; `nil` if unreadable).
    ///
    /// When that window is already a managed ring member, window membership hasn't changed — and Strip
    /// deliberately does **not** follow external focus (`apply()` only re-focuses when the focus-slot
    /// occupant changes), so there is genuinely nothing to do. We skip the full `allWindows()` sweep
    /// entirely: the dominant ~32ms main-thread enumeration cost that activation churn used to pay for
    /// no benefit (perf 1.1 second half). When the focused window is unknown — it could be a brand-new
    /// window, or a membership change whose own notification we missed — fall back to a full reconcile
    /// so nothing is stranded.
    public func handleExternalActivation(pid: pid_t, focusedWindowID id: CGWindowID?) {
        guard !isSuspended else { return }
        if let id, windowsById[id] != nil {
            Signpost.log.emitEvent("reconcile.skip") // membership unchanged → no enumeration
            return
        }
        refreshAndApply() // unknown focused window → full fallback
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
        guard !isSuspended, state.ring.contains(id), var w = windowsById[id] else { return }

        // Refresh the cached frame to where the user actually left the window. The animator re-seeds
        // this window (it was just `forget`-ten) from the controller-supplied `current` frame rather
        // than reading AX itself, so this keeps the snap-back gliding from the drop point (perf:
        // animate seeding) instead of jumping from the stale pre-drag slot.
        let live = w.ax.frame
        if let live { w.frame = live; windowsById[id] = w }

        if wasResize, id == dominantWindowId(), let live {
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
        guard Log.verbose else { return }
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

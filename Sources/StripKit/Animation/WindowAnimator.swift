import AppKit
import ApplicationServices
import QuartzCore

/// Drives real windows to their target frames with a display-link-paced spring — the technique
/// proven by rift/OmniWM for smooth, no-SIP window motion:
///   • a `CADisplayLink` ticks at the display's refresh rate,
///   • each window's frame is integrated toward its target by a spring,
///   • frames are written via the Accessibility API every tick, **off the main thread** on a
///     per-app serial queue (so a slow app can't stall the loop), dropping frames that would
///     overlap an in-flight write,
///   • `AXEnhancedUserInterface` is disabled on every involved app for the duration so AppKit
///     doesn't fight the moves.
public final class WindowAnimator: NSObject {
    private struct Entry {
        var ax: AXWindow
        var spring: RectSpring
        var target: CGRect
        /// Per-window spring override (e.g. a crisp snap-back); `nil` uses the animator's `config`.
        var config: SpringConfig?
    }

    /// One-shot spring applied to every window touched by the *next* `animate(_:on:)`, then cleared.
    /// Set via `requestSnapBack()` so a hand-dragged window returns crisply without changing the
    /// user's chosen film-slide feel.
    private var pendingConfigOverride: SpringConfig?

    private var entries: [CGWindowID: Entry] = [:]
    private var inFlight: Set<CGWindowID> = []
    private var queues: [pid_t: DispatchQueue] = [:]
    private var suppressedApps: [pid_t: AXUIElement] = [:]
    private var failures = WriteFailureTracker()

    /// Until-when each window counts as "driven by us" (M7 respect-user-drags). Every frame we write
    /// stamps this a short `graceInterval` into the future; `isDriving(_:)` consults it so the window
    /// observer can tell the `AXMoved`/`AXResized` our own writes generate — which keep arriving for a
    /// beat after the final write lands — from a genuine user drag. Quartz media-time base (the same
    /// clock as the display link), so it's monotonic and immune to wall-clock changes.
    private var drivenUntil: [CGWindowID: CFTimeInterval] = [:]
    /// How long after our last write a window stays "driven" — covers the lag between our AX write
    /// and the matching move/resize notification landing on the main run loop.
    private let graceInterval: CFTimeInterval = 0.25

    /// Fired (on the main thread) when a window's AX writes have failed enough to call it dead —
    /// a stale element after an app relaunch/crash. The controller drops it from the strip so a
    /// phantom window doesn't wedge a slot. (M7 AX-drop recovery.)
    public var onWindowLost: ((CGWindowID) -> Void)?

    private var displayLink: CADisplayLink?
    private var linkScreen: NSScreen?
    private var lastTimestamp: CFTimeInterval = 0
    public var config: SpringConfig = .track

    /// The window the focus ring should track. The animator reports its live frame so the ring can
    /// follow it as it springs. `nil` hides the ring.
    public var focusedID: CGWindowID?
    /// Fired with the focused window's current frame (Quartz global) each tick, and once when motion
    /// starts/snaps/settles. `nil` when there's no focused window to frame.
    public var onFocusFrame: ((CGRect?) -> Void)?

    public override init() { super.init() }

    /// Set/replace the full set of windows to drive. New windows start from their live frame so
    /// they glide from where they are; windows omitted here stop being animated.
    public func animate(_ targets: [(ax: AXWindow, frame: CGRect)], on screen: NSScreen) {
        let keepIds = Set(targets.map { $0.ax.windowID })

        // Drop windows no longer present.
        for id in entries.keys where !keepIds.contains(id) {
            entries[id] = nil; inFlight.remove(id); drivenUntil[id] = nil; failures.forget(id)
        }

        for t in targets {
            guard let id = t.ax.windowIDOrNil else { continue }
            if var existing = entries[id] {
                existing.target = t.frame
                existing.ax = t.ax // use the freshest AX handle after a re-scan
                existing.config = pendingConfigOverride // nil on a normal apply → back to global feel
                entries[id] = existing
            } else {
                let start = t.ax.frame ?? t.frame
                entries[id] = Entry(ax: t.ax, spring: RectSpring(start), target: t.frame,
                                    config: pendingConfigOverride)
            }
            // Suppress Enhanced UI on this app for the duration of motion.
            let pid = t.ax.pid
            if suppressedApps[pid] == nil {
                let appEl = AXUIElementCreateApplication(pid)
                EnhancedUI.set(false, on: appEl)
                suppressedApps[pid] = appEl
            }
        }

        pendingConfigOverride = nil // one-shot: consumed by this animate
        ensureRunning(on: screen)
        emitFocusFrame() // place the ring at the window's current position right away
    }

    /// Make the next `animate(_:on:)` drive its windows with a crisp snap-back spring instead of the
    /// current film-slide feel — used when re-absorbing a hand-dragged window (M7).
    public func requestSnapBack(_ cfg: SpringConfig = .snapBack) { pendingConfigOverride = cfg }

    /// Forget all cached spring state so the next `animate(_:on:)` re-seats every window from its
    /// **live** frame. Needed after the user has freely moved windows while Strip was suspended
    /// (release-all, M7): without this the animator believes each window is still at its old slot
    /// and stays "settled," so resuming wouldn't visibly pull the rearranged windows back in.
    public func reset() {
        entries.removeAll()
        inFlight.removeAll()
        drivenUntil.removeAll()
        failures = WriteFailureTracker()
    }

    /// Forget just one window's cached spring/grace so the next `animate(_:on:)` re-seats it from its
    /// **live** frame — the per-window analogue of `reset()`. Used when the user has dragged a single
    /// window behind our back (M7 respect-user-drags): its `spring.current` is now stale, so without
    /// this the window would either no-op (move snap-back) or visibly jump from its old slot before
    /// springing (resize-keep) instead of gliding from where the user left it.
    public func forget(_ id: CGWindowID) {
        entries[id] = nil
        inFlight.remove(id)
        drivenUntil[id] = nil
        failures.forget(id)
    }

    /// Whether we are (or just were) the ones moving window `id` — so the observer can ignore the
    /// `AXMoved`/`AXResized` notifications our own frame writes generate and only react to real user
    /// drags. True while a write is in flight, while the window is still springing, or within
    /// `graceInterval` of our last write to it.
    public func isDriving(_ id: CGWindowID) -> Bool {
        if inFlight.contains(id) { return true }
        if let e = entries[id], !e.spring.settled(near: e.target) { return true }
        if let until = drivenUntil[id], CACurrentMediaTime() < until { return true }
        return false
    }

    /// Apply targets instantly with no animation (used when animation is disabled).
    public func snap(_ targets: [(ax: AXWindow, frame: CGRect)]) {
        for t in targets {
            EnhancedUI.suppressed(on: AXUIElementCreateApplication(t.ax.pid)) { t.ax.setFrame(t.frame) }
            if let id = t.ax.windowIDOrNil { drivenUntil[id] = CACurrentMediaTime() + graceInterval }
        }
        // No ticking when snapping, so report the focused window's resting frame directly.
        if let id = focusedID, let t = targets.first(where: { $0.ax.windowIDOrNil == id }) {
            onFocusFrame?(t.frame)
        } else {
            onFocusFrame?(nil)
        }
    }

    // MARK: - Display link

    private func ensureRunning(on screen: NSScreen) {
        if displayLink == nil || linkScreen != screen {
            displayLink?.invalidate()
            let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            linkScreen = screen
            lastTimestamp = 0
        }
        displayLink?.isPaused = false
    }

    private func stop() {
        displayLink?.isPaused = true
        // Restore Enhanced UI on every app we touched.
        for (_, appEl) in suppressedApps { EnhancedUI.set(true, on: appEl) }
        suppressedApps.removeAll()
        lastTimestamp = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        var dt = lastTimestamp == 0 ? (1.0 / 60.0) : (now - lastTimestamp)
        lastTimestamp = now
        dt = min(max(dt, 1.0 / 240.0), 1.0 / 30.0) // clamp against hitches

        var allSettled = true
        for (id, var entry) in entries {
            entry.spring.step(to: entry.target, dt: dt, entry.config ?? config)
            let settled = entry.spring.settled(near: entry.target)
            if settled {
                entry.spring = RectSpring(entry.target) // snap exact
            } else {
                allSettled = false
            }
            entries[id] = entry
            write(id: id, frame: settled ? entry.target : entry.spring.current, ax: entry.ax)
        }

        emitFocusFrame()
        if allSettled { stop() }
    }

    /// Report the focused window's current animated frame (or its target once settled) to `onFocusFrame`.
    private func emitFocusFrame() {
        guard let id = focusedID, let e = entries[id] else { onFocusFrame?(nil); return }
        onFocusFrame?(e.spring.settled(near: e.target) ? e.target : e.spring.current)
    }

    /// Write a frame off the main thread on the app's serial queue, dropping overlapping writes.
    private func write(id: CGWindowID, frame: CGRect, ax: AXWindow) {
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        // Mark this window driven by us; the notification our write triggers may land a beat later,
        // so keep the grace alive `graceInterval` past now.
        drivenUntil[id] = CACurrentMediaTime() + graceInterval
        let queue = queues[ax.pid] ?? {
            let q = DispatchQueue(label: "com.spike.strip.ax.\(ax.pid)")
            queues[ax.pid] = q
            return q
        }()
        queue.async { [weak self] in
            let err = ax.setFrame(frame)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(id)
                if self.failures.record(id, error: err) {
                    // The element is dead — stop driving it and tell the controller to drop it.
                    self.entries[id] = nil
                    self.drivenUntil[id] = nil
                    self.failures.forget(id)
                    self.onWindowLost?(id)
                }
            }
        }
    }
}

private extension AXWindow {
    var windowID: CGWindowID { axWindowID(element) ?? 0 }
    var windowIDOrNil: CGWindowID? { axWindowID(element) }
}

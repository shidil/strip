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
    }

    private var entries: [CGWindowID: Entry] = [:]
    private var inFlight: Set<CGWindowID> = []
    private var queues: [pid_t: DispatchQueue] = [:]
    private var suppressedApps: [pid_t: AXUIElement] = [:]
    private var failures = WriteFailureTracker()

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
            entries[id] = nil; inFlight.remove(id); failures.forget(id)
        }

        for t in targets {
            guard let id = t.ax.windowIDOrNil else { continue }
            if var existing = entries[id] {
                existing.target = t.frame
                existing.ax = t.ax // use the freshest AX handle after a re-scan
                entries[id] = existing
            } else {
                let start = t.ax.frame ?? t.frame
                entries[id] = Entry(ax: t.ax, spring: RectSpring(start), target: t.frame)
            }
            // Suppress Enhanced UI on this app for the duration of motion.
            let pid = t.ax.pid
            if suppressedApps[pid] == nil {
                let appEl = AXUIElementCreateApplication(pid)
                EnhancedUI.set(false, on: appEl)
                suppressedApps[pid] = appEl
            }
        }

        ensureRunning(on: screen)
        emitFocusFrame() // place the ring at the window's current position right away
    }

    /// Forget all cached spring state so the next `animate(_:on:)` re-seats every window from its
    /// **live** frame. Needed after the user has freely moved windows while Strip was suspended
    /// (release-all, M7): without this the animator believes each window is still at its old slot
    /// and stays "settled," so resuming wouldn't visibly pull the rearranged windows back in.
    public func reset() {
        entries.removeAll()
        inFlight.removeAll()
        failures = WriteFailureTracker()
    }

    /// Apply targets instantly with no animation (used when animation is disabled).
    public func snap(_ targets: [(ax: AXWindow, frame: CGRect)]) {
        for t in targets {
            EnhancedUI.suppressed(on: AXUIElementCreateApplication(t.ax.pid)) { t.ax.setFrame(t.frame) }
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
            entry.spring.step(to: entry.target, dt: dt, config)
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

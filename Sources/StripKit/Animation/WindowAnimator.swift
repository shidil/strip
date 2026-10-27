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

    /// One-shot set of windows the *next* `animate(_:on:)` should snap straight to their target
    /// (seeded at the target so the spring is already settled) instead of springing — for apps that
    /// re-quantize their size every frame (terminals). Cleared after that animate.
    private var pendingSnapIDs: Set<CGWindowID> = []

    private var entries: [CGWindowID: Entry] = [:]
    /// The last frame we actually enqueued an AX write for, per window. Drives two perf-1.2 cuts:
    /// (a) once a window is settled and its target frame has been written, stop re-writing it every
    /// tick just because a sibling is still moving; (b) when the next frame's size matches this one's
    /// (a pure slide), skip the clamp-defeat leading `setSize`. Keyed on the full frame so a snap to a
    /// *new* position still differs and writes. Cleared whenever a window leaves the animation.
    private var lastWritten: [CGWindowID: CGRect] = [:]
    private var inFlight: Set<CGWindowID> = []
    private var queues: [pid_t: DispatchQueue] = [:]
    private var suppressedApps: [pid_t: AXUIElement] = [:]
    /// Work waiting for an app's Enhanced UI to come back on (`whenEnhancedUIRestored`), run on main
    /// right after `stop()`'s restore lands on that app's AX queue.
    private var afterRestore: [pid_t: [() -> Void]] = [:]
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

    /// Fired (on the main thread) once a window's motion settles if the real, live AX frame doesn't
    /// match what we commanded — an app can silently clamp a resize to its own minimum content size
    /// (a harder constraint than the OS-level clamping `AXWindow.setFrame`'s double-`setSize` idiom
    /// defeats; see BUGS.md "min-size clamp"). The controller reconciles its cached frame to reality;
    /// this class doesn't retry or fight the clamp.
    public var onFrameClamped: ((CGWindowID, _ requested: CGRect, _ actual: CGRect) -> Void)?

    /// Loose equality for comparing a commanded frame against a live AX read-back — needs slack wider
    /// than the spring's own 0.5px settle threshold (`SpringScalar.settled`) to absorb real-world
    /// integer rounding on the read-back. `internal static` (not `private`) so it's unit-testable
    /// without spinning up a live animator (display link + real screen).
    internal static func frameMatches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1.5) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

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

    /// Set/replace the full set of windows to drive. A new window's spring is seeded from `current`
    /// (its live frame, which the controller already read during `refresh()`) so it glides from where
    /// it is — no synchronous AX read on the main thread here (perf: animate seeding). Windows omitted
    /// here stop being animated.
    public func animate(_ targets: [(ax: AXWindow, frame: CGRect, current: CGRect)], on screen: NSScreen) {
        let sp = Signpost.log
        let animateState = sp.beginInterval("animate")
        defer { sp.endInterval("animate", animateState, "targets=\(targets.count)") }

        let keepIds = Set(targets.map { $0.ax.windowID })

        // Drop windows no longer present.
        for id in entries.keys where !keepIds.contains(id) {
            entries[id] = nil; inFlight.remove(id); drivenUntil[id] = nil
            lastWritten[id] = nil; failures.forget(id)
        }

        for t in targets {
            guard let id = t.ax.windowIDOrNil else { continue }
            let snap = pendingSnapIDs.contains(id)
            if var existing = entries[id] {
                existing.target = t.frame
                existing.ax = t.ax // use the freshest AX handle after a re-scan
                existing.config = pendingConfigOverride // nil on a normal apply → back to global feel
                if snap { existing.spring = RectSpring(t.frame) } // already at target → one write, no staircase
                entries[id] = existing
            } else {
                let start = snap ? t.frame : t.current
                entries[id] = Entry(ax: t.ax, spring: RectSpring(start), target: t.frame,
                                    config: pendingConfigOverride)
            }
            // Suppress Enhanced UI on this app for the duration of motion. The AX write goes on the
            // app's serial queue (off the main thread, before any frame write to it — same FIFO queue),
            // so a slow app's attribute write can't stall the host main thread (perf: animate seeding).
            let pid = t.ax.pid
            if suppressedApps[pid] == nil {
                let appEl = AXUIElementCreateApplication(pid)
                suppressedApps[pid] = appEl
                queue(for: pid).async { EnhancedUI.set(false, on: appEl) }
            }
        }

        pendingConfigOverride = nil // one-shot: consumed by this animate
        pendingSnapIDs = []
        ensureRunning(on: screen)
        emitFocusFrame() // place the ring at the window's current position right away
    }

    /// Make the next `animate(_:on:)` drive its windows with a crisp snap-back spring instead of the
    /// current film-slide feel — used when re-absorbing a hand-dragged window (M7).
    public func requestSnapBack(_ cfg: SpringConfig = .snapBack) { pendingConfigOverride = cfg }

    /// Mark windows the next `animate(_:on:)` should snap (not spring) to their target — for
    /// size-quantizing apps (terminals) whose per-frame re-quantization makes a spring staircase.
    public func snapNext(_ ids: Set<CGWindowID>) { pendingSnapIDs = ids }

    /// Forget all cached spring state so the next `animate(_:on:)` re-seats every window from its
    /// **live** frame. Needed after the user has freely moved windows while Strip was suspended
    /// (release-all, M7): without this the animator believes each window is still at its old slot
    /// and stays "settled," so resuming wouldn't visibly pull the rearranged windows back in.
    public func reset() {
        entries.removeAll()
        inFlight.removeAll()
        drivenUntil.removeAll()
        lastWritten.removeAll()
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
        lastWritten[id] = nil
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

    /// The app's serial write queue (created on demand). All AX writes for a pid — frame writes and
    /// the Enhanced-UI toggles — share it, so they stay ordered and off the main thread.
    private func queue(for pid: pid_t) -> DispatchQueue {
        if let q = queues[pid] { return q }
        let q = DispatchQueue(label: "io.github.shidil.strip.ax.\(pid)")
        queues[pid] = q
        return q
    }

    /// Run the cross-process AX focus writes (mark main/focused, raise) OFF the main thread, on the
    /// app's serial AX queue (the same queue as its frame writes, so the two stay ordered). This is
    /// the ~20ms-for-Electron part that, run on main for every step of a fast slide, starves the
    /// `.main` display-link tick and freezes the animation. The AppKit app-activation half stays on
    /// the main thread at the call site (`AXWindow.activateApp`). See StripController.scheduleFocus.
    public func focusAttributes(_ ax: AXWindow) {
        queue(for: ax.pid).async { ax.focusAttributes() }
    }

    /// Run `work` on main once `pid`'s Enhanced UI is on: immediately when no motion is suppressing
    /// it, else right after this motion's restore lands. Reading an app's AX tree mid-motion sees the
    /// suppressed state — Firefox collapses to ~5 nodes with no tab bar while it's off (probed
    /// 2026-10-26: 48 nodes / 11 tab buttons on, 5 / 0 off) — so tab scans wait on this.
    public func whenEnhancedUIRestored(pid: pid_t, _ work: @escaping () -> Void) {
        guard suppressedApps[pid] != nil else { work(); return }
        afterRestore[pid, default: []].append(work)
    }

    /// Run arbitrary AX `work` for `pid` on that app's serial AX queue — ordered with its frame writes
    /// and focus hand-off (used to press a tab picked in the Overview search before re-centering).
    public func performAX(pid: pid_t, _ work: @escaping () -> Void) {
        queue(for: pid).async(execute: work)
    }

    /// Apply targets instantly with no animation (used when animation is disabled). `current` (the
    /// live seed) is unused on the snap path — windows jump straight to `frame`.
    public func snap(_ targets: [(ax: AXWindow, frame: CGRect, current: CGRect)]) {
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
        // Restore Enhanced UI on every app we touched — off-main on each app's serial queue, so it
        // runs after that app's final frame write (FIFO) and never blocks the main thread.
        for (pid, appEl) in suppressedApps { queue(for: pid).async { EnhancedUI.set(true, on: appEl) } }
        suppressedApps.removeAll()
        // Same FIFO queue as the restore, so waiting work only starts once the attribute is back on.
        // Re-checked on main: if a new motion re-suppressed this app meanwhile, the work waits again.
        for (pid, works) in afterRestore {
            queue(for: pid).async {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return works.forEach { $0() } }
                    works.forEach { self.whenEnhancedUIRestored(pid: pid, $0) }
                }
            }
        }
        afterRestore.removeAll()
        lastTimestamp = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Per-frame budget interval. No interpolated message — the message must never allocate a
        // String on this loop. Surfaces frames whose duration exceeds the display's refresh budget.
        let frameState = Signpost.log.beginInterval("frame")
        defer { Signpost.log.endInterval("frame", frameState) }

        let now = link.timestamp
        var dt = lastTimestamp == 0 ? (1.0 / 60.0) : (now - lastTimestamp)
        lastTimestamp = now
        dt = min(max(dt, 1.0 / 240.0), 1.0 / 30.0) // clamp against hitches

        // `allDone` is stricter than "all springs settled": a window is only done once its *final*
        // target frame has actually been enqueued. A settle-frame write dropped behind an in-flight
        // one (below) keeps the loop alive so we retry, rather than leaving the window a frame short.
        var allDone = true
        for (id, var entry) in entries {
            entry.spring.step(to: entry.target, dt: dt, entry.config ?? config)
            let settled = entry.spring.settled(near: entry.target)
            if settled {
                entry.spring = RectSpring(entry.target) // snap exact
                entries[id] = entry
                // Settled and we've already delivered this exact frame — stop paying AX IPC every
                // tick just because a sibling is still moving (perf 1.2a).
                if lastWritten[id] == entry.target { continue }
                if !write(id: id, frame: entry.target, ax: entry.ax, verifyOnSettle: true) { allDone = false }
            } else {
                entries[id] = entry
                allDone = false
                _ = write(id: id, frame: entry.spring.current, ax: entry.ax)
            }
        }

        emitFocusFrame()
        if allDone { stop() }
    }

    /// Re-report the focused window's current frame on demand — used when the focus ring is toggled
    /// back on while motion is settled (no tick would otherwise fire to place it).
    public func reemitFocusFrame() { emitFocusFrame() }

    /// Adopt the app's *achieved* frame as this window's resting state — called by the controller
    /// when the settle read-back reveals the app clamped our commanded frame (`onFrameClamped`).
    /// Retargets the entry and seeds its spring at `frame` so the next tick doesn't re-fight the
    /// app, records it as `lastWritten` so the settle branch's already-delivered skip holds, and
    /// re-emits the focus frame if this is the focused window — the ring then hugs reality even in
    /// the unsatisfiable-overlap case. Runs on the main thread (the `onFrameClamped` dispatch
    /// already hops there); a window dropped between settle and callback is a no-op.
    public func acceptReality(id: CGWindowID, frame: CGRect) {
        guard var e = entries[id] else { return }
        e.target = frame
        e.spring = RectSpring(frame)
        entries[id] = e
        lastWritten[id] = frame
        if id == focusedID { emitFocusFrame() }
    }

    /// The frame this window is currently being driven toward (nil if not animated). Lets the
    /// controller's delayed clamp-confirm check detect that a newer apply retargeted the window in
    /// the meantime — in which case the stale clamp teaches nothing.
    public func currentTarget(_ id: CGWindowID) -> CGRect? { entries[id]?.target }

    /// Report the focused window's current animated frame (or its target once settled) to `onFocusFrame`.
    private func emitFocusFrame() {
        guard let id = focusedID, let e = entries[id] else { onFocusFrame?(nil); return }
        onFocusFrame?(e.spring.settled(near: e.target) ? e.target : e.spring.current)
    }

    /// Write a frame off the main thread on the app's serial queue, dropping overlapping writes.
    /// Returns `true` if the write was enqueued, `false` if it was dropped (a previous write to this
    /// window is still in flight) — the caller retries dropped settle-frames so a window never ends a
    /// frame short of its target.
    /// `verifyOnSettle` requests a one-shot read-back of the real AX frame after this write, to catch
    /// an app silently clamping the resize to its own minimum content size — set `true` only by the
    /// settle-branch call in `tick()`, which (via the `lastWritten` skip above) fires exactly once
    /// per genuinely new target, not every tick, so this stays off the hot path.
    @discardableResult
    private func write(id: CGWindowID, frame: CGRect, ax: AXWindow, verifyOnSettle: Bool = false) -> Bool {
        let sp = Signpost.log
        // The silent backpressure drop: a write requested while the previous one is still in flight
        // on the per-pid queue. Each emit is one occurrence — count them in Instruments to quantify
        // how often a slow app starves its own motion. Integer interpolation only (non-allocating).
        guard !inFlight.contains(id) else { sp.emitEvent("inFlightDrop", "id=\(id)"); return false }
        inFlight.insert(id)
        sp.emitEvent("setFrame.enqueue", "id=\(id)")
        // Mark this window driven by us; the notification our write triggers may land a beat later,
        // so keep the grace alive `graceInterval` past now.
        drivenUntil[id] = CACurrentMediaTime() + graceInterval
        // Pure-move frame (size unchanged since the last write) → the clamp-defeat leading setSize is
        // a no-op, so skip it; resize frames keep the full double-set (perf 1.2b). Decide before
        // recording this frame as the new `lastWritten`.
        let skipInitialResize = lastWritten[id]?.size == frame.size
        lastWritten[id] = frame
        queue(for: ax.pid).async { [weak self] in
            let err = ax.setFrame(frame, skipInitialResize: skipInitialResize)
            // One extra per-element AX read, off-main on this same per-pid queue — only for the write
            // that claims to finish the motion, not every tick (see doc comment above).
            let achieved = verifyOnSettle ? ax.frame : nil
            sp.emitEvent("setFrame.done", "id=\(id) err=\(err.rawValue)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(id)
                if self.failures.record(id, error: err) {
                    // The element is dead — stop driving it and tell the controller to drop it.
                    self.entries[id] = nil
                    self.drivenUntil[id] = nil
                    self.lastWritten[id] = nil
                    self.failures.forget(id)
                    self.onWindowLost?(id)
                    return
                }
                if verifyOnSettle, err == .success, let achieved, !Self.frameMatches(achieved, frame) {
                    self.onFrameClamped?(id, frame, achieved)
                }
            }
        }
        return true
    }
}

private extension AXWindow {
    var windowID: CGWindowID { axWindowID(element) ?? 0 }
    var windowIDOrNil: CGWindowID? { axWindowID(element) }
}

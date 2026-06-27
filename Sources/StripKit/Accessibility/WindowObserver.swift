import AppKit
import ApplicationServices
import QuartzCore

/// Watches the system for window and app lifecycle changes and fires a single **debounced** callback
/// so the strip can re-tile itself. This is what makes Strip *auto-react* (M6) instead of only
/// re-tiling when you press a hotkey — the headline daily-driver gap.
///
/// Two event sources funnel into one coalesced reconcile:
///  - A per-app `AXObserver` (run-loop source on the main loop) for window create/destroy/
///    miniaturize and focus changes within each regular app.
///  - `NSWorkspace` notifications for app launch/terminate/activate/hide.
///
/// Notifications fire in **bursts** (opening one app emits several), so every event just
/// (re)schedules a short timer; only the trailing edge actually calls `onReconcile`, which does a
/// full `StripController.refreshAndApply()`.
///
/// **Move/resize (M7 respect-user-drags)** are different: `kAXMoved`/`kAXResized` post on the
/// **window** element, not the app element, so we register them per-window (attach on window-created,
/// re-synced on activation; the per-app `AXObserver` watches both the app and its windows). Every
/// such notification is first run past `isAnimatorDriving` — if *we* moved the window (the animator's
/// own frame writes), it's ignored; otherwise it's a genuine user drag, debounced onto a trailing
/// edge `onUserDrag` (the user has stopped moving) so we never fight a drag in progress.
public final class WindowObserver {
    /// Called (on the main thread, debounced) whenever window *membership* may have changed and a full
    /// re-enumeration is warranted (app launch/quit/hide, window create/destroy/miniaturize).
    public var onReconcile: (() -> Void)?

    /// Called (on the main thread, debounced) on a **pure focus/activation** event (Cmd-Tab,
    /// focused/main-window-changed) that changed no window membership. Carries the activated app's
    /// `pid` and the `CGWindowID` of its now-focused window (read cheaply; `nil` if unreadable) so the
    /// controller can skip the full `allWindows()` sweep when that window is already managed, and only
    /// fall back to a full reconcile when it's unknown (perf 1.1 second half).
    public var onFocusActivation: ((_ pid: pid_t, _ focusedWindowID: CGWindowID?) -> Void)?

    /// Asked, on the main thread, whether the animator is currently driving a window — so its own
    /// frame writes don't read as user drags. Returns `false` (treat as user) when unset.
    public var isAnimatorDriving: ((CGWindowID) -> Bool)?

    /// Called (main thread, trailing-edge debounced) when the user has finished dragging window `id`.
    /// `wasResize` is true if any `kAXResized` was seen during the gesture (resize takes precedence
    /// over the incidental origin change a top/left-edge resize also produces).
    public var onUserDrag: ((_ id: CGWindowID, _ wasResize: Bool) -> Void)?

    private let workspace = NSWorkspace.shared
    private var observers: [pid_t: AXObserver] = [:]
    /// Window elements we've added move/resize notifications to, keyed by app, deduped by window id.
    /// Rebuilt on each full re-enumeration so it stays bounded across long-lived apps.
    private var watchedWindows: [pid_t: Set<CGWindowID>] = [:]
    private var pending: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.075

    /// Sticky path decision for the current debounce window (perf 1.1 second half). Any
    /// membership-changing event sets `pendingFullReconcile`; pure focus/activation events only record
    /// `pendingFocusPID`. The trailing edge then takes the full path if *any* membership event landed in
    /// the window (membership wins), else the lightweight focus path — so a focus event arriving last in
    /// a burst can't downgrade a real membership change that arrived earlier. Reset on fire.
    private var pendingFullReconcile = false
    private var pendingFocusPID: pid_t?

    /// Per-window in-flight user gestures: id → did we see a resize (vs. a pure move). Flushed to
    /// `onUserDrag` once the gesture ends.
    private var pendingDrags: [CGWindowID: Bool] = [:]
    private var dragPending: DispatchWorkItem?
    /// Fallback flush delay when no mouse bracket is seen (e.g. a keyboard-driven move). The normal
    /// path flushes on `leftMouseUp`, which is precise and never fires mid-drag.
    private let dragDebounce: TimeInterval = 0.18
    /// Settle after `leftMouseUp` before flushing. Near-zero (next run-loop turn): the window is
    /// already at its final position on release and the controller reads its frame live, so a longer
    /// wait would just add visible lag before the snap-back.
    private let mouseUpSettle: TimeInterval = 0.0

    /// A global left-button monitor brackets drags (M7). While the button is held we **suspend** the
    /// auto-react reconcile/apply entirely — otherwise the focus change from *grabbing* a window
    /// triggers a reconcile that writes the window back to its slot mid-drag (the fight/beachball) and
    /// stamps its grace, swallowing the very drag events we need. On release we flush the gesture and
    /// then let any reconcile deferred during the hold catch up.
    private var mouseMonitor: Any?
    private var leftMouseDown = false
    private var reconcileDeferred = false

    /// Self-induced-activation suppression (perf 1.1). When Strip's own `apply()` moves keyboard
    /// focus it calls `AXWindow.focus()` → `NSRunningApplication.activate()`, which fires *both* a
    /// `didActivateApplication` (→ `appChanged`) **and** AX focus/main-window-changed notifications on
    /// the app element (→ the callback's `default` case). Both schedule a full ~40–110ms `allWindows()`
    /// reconcile that discovers nothing new — the Phase 0 trace's biggest avoidable cost. The
    /// controller stamps the pid it's about to activate here, and both paths drop events for that pid
    /// within `selfActivationGrace`. Kept time-based (not one-shot) so it survives whichever of the
    /// several near-simultaneous events arrives first.
    private var selfActivatedPID: pid_t?
    private var selfActivatedUntil: CFTimeInterval = 0
    private let selfActivationGrace: CFTimeInterval = 0.2

    /// Tell the observer that Strip itself is about to activate `pid` (to move focus), so the
    /// resulting activation/focus notifications don't trigger a redundant reconcile. `now` is
    /// injectable for tests; production callers use the monotonic media clock.
    public func ignoreActivation(of pid: pid_t, now: CFTimeInterval = CACurrentMediaTime()) {
        selfActivatedPID = pid
        selfActivatedUntil = now + selfActivationGrace
    }

    /// Whether an activation/focus event for `pid` at `now` is one Strip induced and should be
    /// ignored. Pure and side-effect-free so it can be unit-tested without AX or notifications.
    func isSelfInducedActivation(pid: pid_t, now: CFTimeInterval) -> Bool {
        pid == selfActivatedPID && now < selfActivatedUntil
    }

    /// App-element notifications we subscribe to. Create/focus/main cover the common "window
    /// appeared / focus moved" cases; miniaturize covers windows leaving and rejoining the strip.
    private static let notifications: [CFString] = [
        kAXWindowCreatedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
        kAXWindowDeminiaturizedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXMainWindowChangedNotification as CFString,
    ]

    /// Per-window notifications, added to each window element rather than the app element.
    private static let windowNotifications: [CFString] = [
        kAXMovedNotification as CFString,
        kAXResizedNotification as CFString,
    ]

    public init() {}

    /// Begin observing. Attaches to every currently-running regular app and subscribes to workspace
    /// launch/quit/activation. Safe to call once, after Accessibility trust is granted.
    public func start() {
        for app in workspace.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            attach(to: app)
        }
        let nc = workspace.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        // Bracket user drags: suspend reconciles while the left button is held, flush on release.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) {
            [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown { self.leftMouseDown = true } else { self.handleMouseUp() }
        }
        // Activation is a *pure focus* event (no membership change) → lightweight path. Hide/unhide
        // change which windows are tileable → full reconcile.
        nc.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(self, selector: #selector(appChanged(_:)), name: name, object: nil)
        }
    }

    /// Stop observing and tear down every AX observer.
    public func stop() {
        workspace.notificationCenter.removeObserver(self)
        for pid in observers.keys { detach(pid: pid) }
        observers.removeAll()
        watchedWindows.removeAll()
        pending?.cancel()
        pending = nil
        dragPending?.cancel()
        dragPending = nil
        pendingDrags.removeAll()
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        leftMouseDown = false
        reconcileDeferred = false
        pendingFullReconcile = false
        pendingFocusPID = nil
    }

    // MARK: - Workspace notifications

    @objc private func appLaunched(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            // The app may not have created its windows yet; the AXObserver we attach will catch
            // them when they appear, and the reconcile below catches anything already present.
            attach(to: app)
        }
        scheduleReconcile()
    }

    @objc private func appTerminated(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            detach(pid: app.processIdentifier)
        }
        scheduleReconcile()
    }

    /// App hide/unhide: which windows are tileable changed, so take the full reconcile path.
    @objc private func appChanged(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            attach(to: app)
        }
        scheduleReconcile()
    }

    /// App activation (Cmd-Tab / `open -a` of a running app): a *pure focus* event that changes no
    /// window membership. Take the lightweight path so we don't pay the full ~32ms `allWindows()`
    /// sweep when the user merely switched apps (perf 1.1 second half).
    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            scheduleReconcile() // no app info → be safe, full reconcile
            return
        }
        // Skip the activation Strip's own focus() caused: we triggered it and nothing changed.
        if isSelfInducedActivation(pid: app.processIdentifier, now: CACurrentMediaTime()) { return }
        // Re-attach defensively: a launch-time AXObserverCreate can fail before the app is ready, and
        // activation is a reliable second chance to hook it. (Its per-app `watchAllWindows` cost is a
        // separate concern — Task 1.4 — not this change's full all-apps sweep.)
        attach(to: app)
        scheduleFocusReconcile(pid: app.processIdentifier)
    }

    // MARK: - Per-app AX observers

    private func attach(to app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        guard pid > 0 else { return }

        // Observer already hooked for this app → nothing to do. We deliberately do NOT re-run
        // `watchAllWindows` here: it's a per-app `kAXWindows` copy on the main thread (measured at
        // p50 21ms / p90 48ms for Electron apps) that used to run on *every* Cmd-Tab via this
        // defensive re-attach (perf 1.4). It's redundant once the observer exists — windows that
        // appear after attach are watched incrementally by `kAXWindowCreated → watch(window:)`, and
        // the app-element notifications (incl. create) were already subscribed at first attach. The
        // re-attach's only real value was a second chance at `AXObserverCreate`, which only matters
        // when it *failed* before (observer still nil) — handled by the create path below.
        if observers[pid] != nil { return }

        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let created else { return }
        let observer = created
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.notifications {
            // Some apps reject some notifications on the app element — harmless; ignore the result.
            AXObserverAddNotification(observer, appElement, n, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer

        // Watch the app's already-existing windows once, at first attach (the only time the app
        // element's `kAXWindowCreated` won't fire for them). New windows arrive via that notification.
        watchAllWindows(of: pid, with: observer)
    }

    /// The single C callback for every app observer. Routes by notification: move/resize are
    /// per-window user-drag candidates; created windows get watched; everything else (re)schedules a
    /// reconcile. Context flows only through `refcon` (the `WindowObserver`), as a C function pointer
    /// can't capture.
    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let me = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        switch name {
        case kAXMovedNotification, kAXResizedNotification:
            if let id = axWindowID(element) {
                me.handleGeometryNotification(id: id, wasResize: name == kAXResizedNotification)
            }
        case kAXWindowCreatedNotification:
            // The element delivered for a window-created notification *is* the new window.
            me.watch(window: element)
            me.scheduleReconcile()
        default:
            // Everything else: focus/main-window-changed (pure focus) vs destroy/miniaturize
            // (membership). Route by classification.
            switch reconcileKind(for: name) {
            case .lightweight:
                // Focused/main-window-changed posts on the app element. Drop the one Strip's own
                // apply() induces for the pid we just activated; otherwise take the lightweight path.
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success else { me.scheduleReconcile(); return }
                if me.isSelfInducedActivation(pid: pid, now: CACurrentMediaTime()) { return }
                me.scheduleFocusReconcile(pid: pid)
            case .full:
                // kAXUIElementDestroyed / kAXWindowMiniaturized / kAXWindowDeminiaturized — membership.
                me.scheduleReconcile()
            }
        }
    }

    /// Add move/resize notifications to every current window of `pid`, rebuilding the watched-id set.
    private func watchAllWindows(of pid: pid_t, with observer: AXObserver) {
        // This is a per-app `kAXWindows` copy on the main thread — the residual main-thread cost on
        // the activation path after perf 1.1 (it runs on every Cmd-Tab via the defensive re-attach).
        // Signposted so Task 1.4 can quantify it before deciding whether to skip it. (perf 1.4 measure)
        let sp = Signpost.log
        let watchState = sp.beginInterval("watchWindows")
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            sp.endInterval("watchWindows", watchState, "pid=\(pid) windows=0")
            return
        }
        var ids: Set<CGWindowID> = []
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for win in windows {
            guard let id = axWindowID(win) else { continue }
            ids.insert(id)
            for n in Self.windowNotifications { AXObserverAddNotification(observer, win, n, refcon) }
        }
        watchedWindows[pid] = ids
        sp.endInterval("watchWindows", watchState, "pid=\(pid) windows=\(ids.count)")
    }

    /// Add move/resize notifications to a single freshly-created window element.
    private func watch(window element: AXUIElement) {
        let pid = pidOf(element)
        guard pid > 0, let observer = observers[pid], let id = axWindowID(element) else { return }
        if watchedWindows[pid]?.contains(id) == true { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.windowNotifications { AXObserverAddNotification(observer, element, n, refcon) }
        watchedWindows[pid, default: []].insert(id)
    }

    private func pidOf(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : 0
    }

    private func detach(pid: pid_t) {
        guard let observer = observers[pid] else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = nil
        watchedWindows[pid] = nil
    }

    // MARK: - User drags (move/resize)

    /// A move/resize landed on a window. If we're driving it (our own animation), ignore; otherwise
    /// it's a user gesture — accumulate it. While the button is held we do nothing else (the gesture
    /// is in progress); the `leftMouseUp` bracket flushes it. The trailing-edge timer is only a
    /// fallback for gestures with no observed mouse bracket (e.g. keyboard-driven moves).
    private func handleGeometryNotification(id: CGWindowID, wasResize: Bool) {
        // While the button is held we've suspended our own applies, so any geometry change is the
        // user — record it unconditionally. The `isDriving` filter only matters on the fallback path
        // (no mouse bracket), where it keeps our own animation writes from arming a flush. Filtering
        // during a held drag is what dropped quick gestures grabbed within the post-settle grace.
        if !leftMouseDown, isAnimatorDriving?(id) == true { return }
        pendingDrags[id] = (pendingDrags[id] ?? false) || wasResize
        guard !leftMouseDown else { return }
        scheduleFlush(after: dragDebounce)
    }

    /// Left button released: settle briefly so the final move/resize notification lands, then flush
    /// the gesture. If nothing was dragged, just catch up any reconcile deferred during the hold.
    private func handleMouseUp() {
        leftMouseDown = false
        if !pendingDrags.isEmpty {
            scheduleFlush(after: mouseUpSettle)
        } else if reconcileDeferred {
            reconcileDeferred = false
            scheduleReconcile()
        }
    }

    private func scheduleFlush(after delay: TimeInterval) {
        dragPending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushDrags() }
        dragPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flushDrags() {
        let drags = pendingDrags
        pendingDrags.removeAll()
        // The drag handler does its own `apply()`, so the reconcile deferred during the hold (almost
        // always just the grab's focus change) would only fire a redundant second pass — a visible
        // double-move. Drop it; the next real window/app event reconciles anyway.
        reconcileDeferred = false
        for (id, wasResize) in drags { onUserDrag?(id, wasResize) }
    }

    // MARK: - Debounce

    /// Whether an AX notification should trigger a full re-enumeration or just a lightweight focus
    /// re-center. Pure and side-effect-free so it can be unit-tested without AX. Only focused/main-
    /// window-changed are membership-preserving; everything else (destroy, miniaturize, …) is full.
    /// Move/resize are handled by the user-drag path, never routed here.
    enum ReconcileKind { case full, lightweight }
    static func reconcileKind(for notification: String) -> ReconcileKind {
        switch notification {
        case kAXFocusedWindowChangedNotification,
             kAXMainWindowChangedNotification:
            return .lightweight
        default:
            return .full
        }
    }

    /// The single action the trailing debounce edge should take given what landed during the window.
    /// Membership wins: any full-reconcile request forces `.full`; otherwise a recorded focus pid
    /// yields `.lightweight`; an empty window yields `.none`. Pure → unit-tested.
    enum BatchAction: Equatable { case full, lightweight(pid_t), none }
    static func batchAction(sawMembership: Bool, focusPID: pid_t?) -> BatchAction {
        if sawMembership { return .full }
        if let pid = focusPID { return .lightweight(pid) }
        return .none
    }

    /// Request a **full** reconcile (membership may have changed). Sticky for the debounce window.
    private func scheduleReconcile() {
        // Reconcile fire-rate: each emit is one (debounced) reconcile request. During a Cmd-Tab/
        // focus storm this rate is the R1 cost driver — Phase 1 (1.1) drops the no-op ones.
        Signpost.log.emitEvent("reconcile")
        pendingFullReconcile = true
        armDebounce()
    }

    /// Request a **lightweight** focus re-center for `pid` (a pure focus/activation event). Only takes
    /// effect at the trailing edge if no membership event also landed in the same window.
    private func scheduleFocusReconcile(pid: pid_t) {
        Signpost.log.emitEvent("reconcile")
        pendingFocusPID = pid
        armDebounce()
    }

    /// Coalesce a burst of notifications into a single trailing-edge fire on the main thread.
    private func armDebounce() {
        // Hold reconciles during a drag — the grab itself fires a focus change, and reconciling
        // mid-drag would write the held window back to its slot. Caught up on mouse-up.
        if leftMouseDown { reconcileDeferred = true; return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireReconcile() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Trailing edge: pick the path from the sticky flags, reset them, and dispatch.
    private func fireReconcile() {
        let action = Self.batchAction(sawMembership: pendingFullReconcile, focusPID: pendingFocusPID)
        pendingFullReconcile = false
        pendingFocusPID = nil
        switch action {
        case .full:
            onReconcile?()
        case .lightweight(let pid):
            // Cheap per-element read (main thread): one `kAXFocusedWindow` on a known app element —
            // unlike the all-apps `kAXWindows` copy, this is not main-bound-degraded and is ~1 IPC.
            onFocusActivation?(pid, focusedWindowID(of: pid))
        case .none:
            break
        }
    }

    /// The `CGWindowID` of `pid`'s currently-focused window, or `nil` if unreadable.
    private func focusedWindowID(of pid: pid_t) -> CGWindowID? {
        let appElement = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        return axWindowID(ref as! AXUIElement)
    }
}

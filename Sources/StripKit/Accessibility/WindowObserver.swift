import AppKit
import ApplicationServices

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
    /// Called (on the main thread, debounced) whenever the window world may have changed.
    public var onReconcile: (() -> Void)?

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
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
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

    @objc private func appChanged(_ note: Notification) {
        // Re-attach defensively: a launch-time AXObserverCreate can fail before the app is ready,
        // and activation is a reliable second chance to hook it.
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            attach(to: app)
        }
        scheduleReconcile()
    }

    // MARK: - Per-app AX observers

    private func attach(to app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        guard pid > 0 else { return }

        let observer: AXObserver
        if let existing = observers[pid] {
            observer = existing
        } else {
            var created: AXObserver?
            guard AXObserverCreate(pid, Self.callback, &created) == .success, let created else { return }
            observer = created
            let appElement = AXUIElementCreateApplication(pid)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for n in Self.notifications {
                // Some apps reject some notifications on the app element — harmless; ignore the result.
                AXObserverAddNotification(observer, appElement, n, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
        }

        // (Re)sync per-window move/resize watches. Runs on every activation too — a launch-time
        // enumeration can fire before the app's windows exist, and re-activation is a reliable
        // second chance; rebuilding the set here also keeps it bounded as windows come and go.
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
            me.scheduleReconcile()
        }
    }

    /// Add move/resize notifications to every current window of `pid`, rebuilding the watched-id set.
    private func watchAllWindows(of pid: pid_t, with observer: AXObserver) {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        var ids: Set<CGWindowID> = []
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for win in windows {
            guard let id = axWindowID(win) else { continue }
            ids.insert(id)
            for n in Self.windowNotifications { AXObserverAddNotification(observer, win, n, refcon) }
        }
        watchedWindows[pid] = ids
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

    /// Coalesce a burst of notifications into a single trailing-edge reconcile on the main thread.
    private func scheduleReconcile() {
        // Hold reconciles during a drag — the grab itself fires a focus change, and reconciling
        // mid-drag would write the held window back to its slot. Caught up on mouse-up.
        if leftMouseDown { reconcileDeferred = true; return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onReconcile?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}

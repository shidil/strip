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
/// full `StripController.refreshAndApply()`. We deliberately do **not** observe move/resize here —
/// that would feed the animator's own writes straight back into a reconcile storm; honoring user
/// drags is M7.
public final class WindowObserver {
    /// Called (on the main thread, debounced) whenever the window world may have changed.
    public var onReconcile: (() -> Void)?

    private let workspace = NSWorkspace.shared
    private var observers: [pid_t: AXObserver] = [:]
    private var pending: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.075

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
        pending?.cancel()
        pending = nil
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
        guard pid > 0, observers[pid] == nil else { return }

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue().scheduleReconcile()
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.notifications {
            // Some apps reject some notifications on the app element — harmless; ignore the result.
            AXObserverAddNotification(observer, appElement, n, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func detach(pid: pid_t) {
        guard let observer = observers[pid] else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = nil
    }

    // MARK: - Debounce

    /// Coalesce a burst of notifications into a single trailing-edge reconcile on the main thread.
    private func scheduleReconcile() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onReconcile?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}

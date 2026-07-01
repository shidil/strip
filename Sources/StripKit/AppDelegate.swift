import AppKit
import ApplicationServices

/// Menu-bar agent entry point. Gates on Accessibility, then tiles the active display's windows
/// into the strip. M1 exposes layout switching (monocle / 2-up / 3-up, focus/equal, slide) through
/// the status-bar menu so the geometry can be verified visually before hotkeys (M2/M3) exist.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = StripController()
    private let hotkeys = HotkeyService()
    private let overlay = OverlayController()
    private let observer = WindowObserver()

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        if AccessibilityService.ensureTrusted(prompt: true) {
            start()
        } else {
            presentPermissionNotice()
            pollForTrust()
        }
    }

    private func start() {
        overlay.onCenter = { [weak self] id in self?.controller.setCenter(id) }
        overlay.onOverviewVisibility = { [weak self] open in self?.hotkeys.setOverviewOpen(open) }
        controller.onRender = { [weak self] snapshot in self?.overlay.update(snapshot) }
        controller.onFocusFrame = { [weak self] frame in self?.overlay.updateFocusRing(frame) }
        controller.refreshAndApply()
        hotkeys.onCommand = { [weak self] command, repeated in self?.handle(command, repeated: repeated) }
        hotkeys.start()
        // Auto-react (M6): re-tile whenever windows/apps come and go, debounced into one reconcile.
        observer.onReconcile = { [weak self] in self?.controller.refreshAndApply() }
        // Perf 1.1: suppress the reconcile our own focus()-driven app activation would otherwise cause.
        controller.onWillActivate = { [weak self] pid in self?.observer.ignoreActivation(of: pid) }
        // Perf 1.1 (second half): route a pure external activation/focus event to the lightweight path
        // — skip the full allWindows() sweep when the focused window is already managed.
        observer.onFocusActivation = { [weak self] pid, id in
            self?.controller.handleExternalActivation(pid: pid, focusedWindowID: id)
        }
        // Respect user drags (M7): tell user moves/resizes from the animator's own writes, and act on
        // a finished drag — snap back, or keep the dominant window's resize.
        observer.isAnimatorDriving = { [weak self] id in self?.controller.isDriving(id) ?? false }
        observer.onUserDrag = { [weak self] id, wasResize in
            self?.controller.handleUserDrag(id: id, wasResize: wasResize)
        }
        observer.start()
        rebuildMenu()
    }

    /// Quit safety (M7): un-park any off-screen windows before we exit so a quit never strands a
    /// window off the display edge. Stop reacting first so nothing re-parks during teardown.
    public func applicationWillTerminate(_ notification: Notification) {
        observer.stop()
        controller.unparkAllOnScreen()
    }

    /// Route a hotkey command to the controller. `repeated` is true for OS auto-repeats (held key),
    /// which navigation paces to a watchable cadence instead of the full repeat rate.
    private func handle(_ command: HotkeyCommand, repeated: Bool = false) {
        // ⌃⌥0 toggles the release/suspend escape hatch.
        if case .releaseAll = command { controller.releaseAll(); rebuildMenu(); return }
        // Any explicit layout/navigation command resumes management first; overlay-only keys don't,
        // so you can pop up help/Overview without un-suspending.
        switch command {
        case .toggleHelp, .toggleOverview, .overview: break
        default: controller.resumeIfSuspended()
        }
        switch command {
        case .slidePrev: controller.rotate(-1, repeated: repeated)
        case .slideNext: controller.rotate(1, repeated: repeated)
        case .focusPrev: controller.focusMove(-1, repeated: repeated)
        case .focusNext: controller.focusMove(1, repeated: repeated)
        case .movePrev: controller.moveFocused(-1)
        case .moveNext: controller.moveFocused(1)
        case .cols(let n): controller.setCols(n)
        case .toggleEmphasis: controller.toggleEmphasis()
        case .cycleTransition: controller.cycleSpring()
        case .togglePin: controller.togglePin()
        case .focusWider: controller.adjustFocusRatio(+0.05)
        case .focusNarrower: controller.adjustFocusRatio(-0.05)
        case .taller: controller.adjustHeight(+0.05)
        case .shorter: controller.adjustHeight(-0.05)
        case .gapTighter: controller.adjustGap(-4)
        case .gapLooser: controller.adjustGap(+4)
        case .releaseAll: break // handled above (early return); listed for exhaustiveness
        case .toggleHelp: overlay.toggleHelp()
        case .toggleOverview: overlay.toggleOverview()
        case .overview(let key):
            switch key {
            case .left: overlay.navigateOverview(.left)
            case .right: overlay.navigateOverview(.right)
            case .up: overlay.navigateOverview(.up)
            case .down: overlay.navigateOverview(.down)
            case .confirm: overlay.confirmOverview()
            case .close: overlay.toggleOverview()
            }
        }
    }

    // MARK: - Status bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▦ Strip"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status: String
        if !AccessibilityService.isTrusted {
            status = "Waiting for Accessibility…"
        } else if controller.isSuspended {
            status = "Released — management paused"
        } else {
            status = "Managing \(controller.managedCount) window(s)"
        }
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        add(menu, "Re-tile / Re-scan", #selector(retile), "r")

        let layout = NSMenu()
        add(layout, "Monocle (1)", #selector(setMonocle), "")
        add(layout, "2-up (2)", #selector(setTwoUp), "")
        add(layout, "3-up (3)", #selector(setThreeUp), "")
        layout.addItem(.separator())
        add(layout, "Focus emphasis", #selector(setFocusEmphasis), "")
        add(layout, "Equal emphasis", #selector(setEqualEmphasis), "")
        let layoutItem = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        layoutItem.submenu = layout
        menu.addItem(layoutItem)

        add(menu, "Slide film ◀ (prev)", #selector(slidePrev), "[")
        add(menu, "Slide film ▶ (next)", #selector(slideNext), "]")
        add(menu, "Pin / unpin focused slot", #selector(togglePin), "p")

        let railMenu = NSMenu()
        for edge in RailEdge.allCases {
            let item = add(railMenu, edge.rawValue.capitalized, #selector(setRailEdge(_:)), "")
            item.state = controller.railEdge == edge ? .on : .off
            item.representedObject = edge
        }
        let railItem = NSMenuItem(title: "Minimap position", action: nil, keyEquivalent: "")
        railItem.submenu = railMenu
        menu.addItem(railItem)

        menu.addItem(.separator())
        add(menu, controller.isSuspended ? "Resume managing (⌃⌥0)" : "Release windows (⌃⌥0)",
            #selector(toggleRelease), "")

        menu.addItem(.separator())
        let ring = add(menu, "Show focus ring", #selector(toggleFocusRing), "")
        ring.state = controller.focusRingEnabled ? .on : .off

        menu.addItem(.separator())
        add(menu, "Overview", #selector(toggleOverview), "")
        add(menu, "Keyboard help…", #selector(toggleHelp), "/")

        menu.addItem(.separator())
        add(menu, "Quit Strip", #selector(quit), "q")

        statusItem.menu = menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Menu actions

    @objc private func retile() { controller.refreshAndApply(); rebuildMenu() }
    @objc private func setMonocle() { controller.setCols(1) }
    @objc private func setTwoUp() { controller.setCols(2) }
    @objc private func setThreeUp() { controller.setCols(3) }
    @objc private func setFocusEmphasis() { controller.setEmphasis(.focus) }
    @objc private func setEqualEmphasis() { controller.setEmphasis(.equal) }
    @objc private func slidePrev() { controller.rotate(-1) }
    @objc private func slideNext() { controller.rotate(1) }
    @objc private func togglePin() { controller.togglePin() }
    @objc private func setRailEdge(_ sender: NSMenuItem) {
        guard let edge = sender.representedObject as? RailEdge else { return }
        controller.setRailEdge(edge)
        rebuildMenu()
    }
    @objc private func toggleRelease() { controller.releaseAll(); rebuildMenu() }
    @objc private func toggleFocusRing() { controller.setFocusRing(!controller.focusRingEnabled); rebuildMenu() }
    @objc private func toggleOverview() { overlay.toggleOverview() }
    @objc private func toggleHelp() { overlay.toggleHelp() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Permission flow

    private func pollForTrust() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AccessibilityService.isTrusted {
                timer.invalidate()
                self.start()
            }
        }
    }

    private func presentPermissionNotice() {
        let alert = NSAlert()
        alert.messageText = "Strip needs Accessibility access"
        alert.informativeText = """
        Grant access in System Settings → Privacy & Security → Accessibility, then Strip will \
        start managing windows automatically. (No SIP changes are required.)
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}

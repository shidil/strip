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
        hotkeys.onCommand = { [weak self] in self?.handle($0) }
        hotkeys.start()
        rebuildMenu()
    }

    /// Route a hotkey command to the controller.
    private func handle(_ command: HotkeyCommand) {
        switch command {
        case .slidePrev: controller.rotate(-1)
        case .slideNext: controller.rotate(1)
        case .focusPrev: controller.focusMove(-1)
        case .focusNext: controller.focusMove(1)
        case .movePrev: controller.moveWindow(-1)
        case .moveNext: controller.moveWindow(1)
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

        let status = AccessibilityService.isTrusted
            ? "Managing \(controller.managedCount) window(s)"
            : "Waiting for Accessibility…"
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

        menu.addItem(.separator())
        add(menu, "Overview", #selector(toggleOverview), "")
        add(menu, "Keyboard help…", #selector(toggleHelp), "/")

        menu.addItem(.separator())
        add(menu, "Quit Strip", #selector(quit), "q")

        statusItem.menu = menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
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

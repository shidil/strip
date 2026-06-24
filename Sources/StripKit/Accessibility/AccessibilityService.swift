import AppKit
import ApplicationServices

/// Enumerates and identifies the real, standard application windows on a given display using the
/// public Accessibility API only. This is the *snapshot* side; live create/destroy/focus
/// observation that drives auto-re-tiling lives in `WindowObserver` (M6).
public final class AccessibilityService {
    public init() {}

    // MARK: - Permission

    /// Whether this process currently holds the Accessibility (AXIsProcessTrusted) grant.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Checks the grant; when `prompt` is true and not yet trusted, shows the system prompt that
    /// deep-links to System Settings → Privacy & Security → Accessibility.
    @discardableResult
    public static func ensureTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Enumeration

    /// All managed standard windows whose center lies on `screen`, ordered by app then on-screen
    /// left-to-right (a stable, sensible initial film order).
    public func windows(on screen: NSScreen) -> [ManagedWindow] {
        let screenRect = screen.quartzFrame
        return allWindows()
            .filter { screenRect.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// All managed standard windows across every running regular app, on every display.
    public func allWindows() -> [ManagedWindow] {
        var result: [ManagedWindow] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            result.append(contentsOf: windows(for: app))
        }
        return result
    }

    private func windows(for app: NSRunningApplication) -> [ManagedWindow] {
        let pid = app.processIdentifier
        guard pid > 0 else { return [] }
        let appElement = AXUIElementCreateApplication(pid)

        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let elements = ref as? [AXUIElement] else { return [] }

        let appName = app.localizedName ?? "App"
        let accentKey = app.bundleIdentifier ?? appName

        return elements.compactMap { element -> ManagedWindow? in
            let w = AXWindow(element: element, pid: pid)
            guard Self.classify(w) == .managed, let frame = w.frame, let id = axWindowID(element) else {
                return nil
            }
            return ManagedWindow(
                id: id, ax: w, appName: appName, accentKey: accentKey,
                title: w.title ?? appName, frame: frame
            )
        }
    }

    /// How Strip should treat a window. Only `.managed` windows are tiled; `.floating` windows are
    /// real app windows we deliberately leave where they are (dialogs, palettes, non-resizable
    /// windows); `.ignored` are not windows we'd ever consider (wrong role, minimized, too small).
    ///
    /// The split between `.floating` and `.ignored` doesn't change M6 behavior — both are simply
    /// left alone — but it names the distinction the M7 "respect user drags" / ignore-rules work
    /// will build on.
    public enum WindowClassification { case managed, floating, ignored }

    /// Conservative classifier (M6): tile only clearly-standard, resizable, usable-size windows;
    /// float the clear-cut leave-alone cases (sheets/dialogs/panels, non-resizable). No per-app
    /// denylist yet — that arrives with the config file in M9.
    public static func classify(_ w: AXWindow) -> WindowClassification {
        guard w.role == (kAXWindowRole as String) else { return .ignored }
        if w.isMinimized { return .ignored }
        guard let f = w.frame, f.width >= 80, f.height >= 80 else { return .ignored }
        // Anything that isn't a plain standard window — dialogs, sheets, system dialogs, floating
        // panels, palettes, unknown subroles — is left in place. (Some apps report no subrole for
        // their main window; allow that as standard.)
        if let sub = w.subrole, sub != (kAXStandardWindowSubrole as String) { return .floating }
        // A window we can't resize can't be tiled sensibly — leave it where the app put it.
        if !w.isResizable { return .floating }
        return .managed
    }
}

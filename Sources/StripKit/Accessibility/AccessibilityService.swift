import AppKit
import ApplicationServices

/// Enumerates and identifies the real, standard application windows on a given display using the
/// public Accessibility API only. (Live focus/create/destroy observation arrives in a later
/// milestone; M0 just needs an accurate snapshot.)
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
            guard isManageable(w), let frame = w.frame, let id = axWindowID(element) else { return nil }
            return ManagedWindow(
                id: id, ax: w, appName: appName, accentKey: accentKey,
                title: w.title ?? appName, frame: frame
            )
        }
    }

    /// A window we are willing to tile: a real, standard, non-minimized window of usable size.
    private func isManageable(_ w: AXWindow) -> Bool {
        guard w.role == (kAXWindowRole as String) else { return false }
        // Standard windows only; some apps report no subrole for their main window, allow that.
        if let sub = w.subrole, sub != (kAXStandardWindowSubrole as String) { return false }
        if w.isMinimized { return false }
        guard let f = w.frame, f.width >= 80, f.height >= 80 else { return false }
        return true
    }
}

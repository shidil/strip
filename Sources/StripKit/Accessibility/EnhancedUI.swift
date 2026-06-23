import AppKit
import ApplicationServices

/// AppKit apps with "Enhanced User Interface" enabled (VoiceOver / some apps turn it on) animate
/// their *own* AX-driven moves/resizes, which fights and lags our per-frame animation. The standard
/// fix (used by rift via `with_enhanced_ui_disabled` and OmniWM around its batches) is to turn the
/// attribute off on the target app before writing frames and restore it after.
enum EnhancedUI {
    private static let attribute = "AXEnhancedUserInterface" as CFString

    /// Reads the current value (defaults to false if unreadable).
    static func isEnabled(_ app: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute, &ref) == .success,
              let v = ref as? Bool else { return false }
        return v
    }

    static func set(_ enabled: Bool, on app: AXUIElement) {
        AXUIElementSetAttributeValue(app, attribute, enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Run `body` with Enhanced UI forced off on `app`, restoring the prior value afterward.
    static func suppressed(on app: AXUIElement, _ body: () -> Void) {
        let was = isEnabled(app)
        if was { set(false, on: app) }
        body()
        if was { set(true, on: app) }
    }
}

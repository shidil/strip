import AppKit
import ApplicationServices

/// A thin, value-typed wrapper over an `AXUIElement` that represents a single application window.
///
/// All reads/writes go through the public Accessibility API only — no private symbols, no SIP.
/// Frames are returned in **Cocoa/AppKit terms intentionally NOT applied here**: the Accessibility
/// API uses a top-left origin with Y growing downward (the "Quartz/global display" coordinate
/// space), which is what we keep internally. Conversion to `NSScreen` (bottom-left) space happens
/// only where we touch AppKit overlays.
public struct AXWindow {
    public let element: AXUIElement
    public let pid: pid_t

    public init(element: AXUIElement, pid: pid_t) {
        self.element = element
        self.pid = pid
    }

    // MARK: - Reads

    public var role: String? { copyString(kAXRoleAttribute) }
    public var subrole: String? { copyString(kAXSubroleAttribute) }
    public var title: String? { copyString(kAXTitleAttribute) }

    public var isMinimized: Bool {
        guard let v = copyValue(kAXMinimizedAttribute) as? Bool else { return false }
        return v
    }

    /// Window frame in Quartz global coordinates (top-left origin, Y down).
    public var frame: CGRect? {
        guard let pos = copyPoint(kAXPositionAttribute), let size = copySize(kAXSizeAttribute) else {
            return nil
        }
        return CGRect(origin: pos, size: size)
    }

    // MARK: - Writes (used by the animator)

    /// Apply a target frame. Uses the rift/OmniWM "set size twice" idiom: setting size, then
    /// position, then size again defeats apps that clamp size to their min/max during the move.
    public func setFrame(_ rect: CGRect) {
        setSize(rect.size)
        setPosition(rect.origin)
        setSize(rect.size)
    }

    public func setPosition(_ p: CGPoint) {
        var pt = p
        guard let value = AXValueCreate(.cgPoint, &pt) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    public func setSize(_ s: CGSize) {
        var sz = s
        guard let value = AXValueCreate(.cgSize, &sz) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    /// Bring this window to the front and make it the focused/main window of its app.
    public func raise() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    // MARK: - Low-level attribute helpers

    private func copyValue(_ attr: String) -> AnyObject? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        return err == .success ? ref : nil
    }

    private func copyString(_ attr: String) -> String? {
        copyValue(attr) as? String
    }

    private func copyPoint(_ attr: String) -> CGPoint? {
        guard let ref = copyValue(attr) else { return nil }
        // CFTypeRef holding an AXValue
        let axValue = ref as! AXValue
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func copySize(_ attr: String) -> CGSize? {
        guard let ref = copyValue(attr) else { return nil }
        let axValue = ref as! AXValue
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}

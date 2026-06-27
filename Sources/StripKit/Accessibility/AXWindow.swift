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

    /// Whether the window's size can actually be set. Probed via `AXUIElementIsAttributeSettable`
    /// on `kAXSize`: a window we can't resize (fixed dialogs, some panels) is never tiled — moving
    /// it without resizing would just shove it around. Defaults to `true` if the probe fails, so a
    /// quirky-but-tileable window isn't wrongly excluded.
    public var isResizable: Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable)
        guard err == .success else { return true }
        return settable.boolValue
    }

    /// Whether this element still refers to a live window. A transiently-busy app can fail an AX
    /// read (`.cannotComplete`) for a window that's perfectly alive, so only a hard
    /// `.invalidUIElement` — the element has been destroyed — counts as dead. Used by `refresh()`
    /// to avoid dropping a ring window just because one enumeration scan missed it.
    public var isAlive: Bool {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref)
        return err != .invalidUIElement
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
    /// Returns the most telling `AXError`: a hard `.invalidUIElement` (the window is gone) wins, so
    /// the animator's AX-drop recovery (M7) can tell a dead element from a transient hiccup.
    ///
    /// `skipInitialResize` drops the *leading* `setSize` — safe only on a pure-move frame (size
    /// unchanged from the last write), where the clamp-defeat first write does nothing. The caller
    /// (the animator, which holds per-window size history) decides; the trailing `setSize` and the
    /// full double-set on resize frames are always preserved. (perf 1.2)
    @discardableResult
    public func setFrame(_ rect: CGRect, skipInitialResize: Bool = false) -> AXError {
        let a: AXError = skipInitialResize ? .success : setSize(rect.size)
        let b = setPosition(rect.origin)
        let c = setSize(rect.size)
        for e in [a, b, c] where e == .invalidUIElement { return .invalidUIElement }
        return b != .success ? b : (a != .success ? a : c)
    }

    @discardableResult
    public func setPosition(_ p: CGPoint) -> AXError {
        var pt = p
        guard let value = AXValueCreate(.cgPoint, &pt) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    public func setSize(_ s: CGSize) -> AXError {
        var sz = s
        guard let value = AXValueCreate(.cgSize, &sz) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    /// Bring this window to the front of its app's window stack (z-order only — does not move
    /// keyboard focus to the app).
    public func raise() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Give this window real keyboard focus: mark it the app's main + focused window, raise it, and
    /// **activate the owning application** so keystrokes are delivered to it. Raising alone only
    /// reorders windows within an app; without activating the app the previously-frontmost app keeps
    /// the keyboard. (Standard no-SIP AX focus path, à la Amethyst/yabai.)
    public func focus() {
        focusAttributes()
        activateApp()
    }

    /// The AX-only half of `focus()`: mark this window the app's main + focused window and raise it
    /// within its app. These are per-element AX writes, so they are **safe off the main thread** (only
    /// the all-apps `kAXWindows` *enumeration* is main-bound). For a busy Electron app each is a
    /// multi-ms cross-process round-trip, so the slide hot path runs these off-main (see
    /// `WindowAnimator.focusAttributes` / `StripController.scheduleFocus`).
    public func focusAttributes() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// The AppKit half of `focus()`: bring this window's app to the foreground. `NSRunningApplication`
    /// is AppKit and **must run on the main thread** — calling it off-main caused sporadic ~400ms
    /// main-thread stalls (a hard freeze mid-slide). Cheap on main (~1–2ms).
    public func activateApp() {
        NSRunningApplication(processIdentifier: pid)?.activate()
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

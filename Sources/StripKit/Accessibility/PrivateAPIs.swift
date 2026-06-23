import ApplicationServices
import CoreGraphics

/// `_AXUIElementGetWindow` maps an `AXUIElement` to its `CGWindowID`. Despite the leading
/// underscore it is **not** a SIP-gated symbol — it runs from a normally-signed process with only
/// the Accessibility grant, and every no-SIP window manager (Amethyst, AeroSpace, rift, OmniWM)
/// relies on it for a stable per-window identity. We use it purely for identity, never to move
/// windows (moves go through the public `kAXPosition`/`kAXSize` API in `AXWindow`).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Returns the `CGWindowID` for an accessibility window element, or `nil` if unavailable.
func axWindowID(_ element: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    return _AXUIElementGetWindow(element, &wid) == .success ? wid : nil
}

// MARK: - Window-server background blur (private SkyLight, no SIP)

/// `CGSSetWindowBackgroundBlurRadius` asks the window server to blur whatever is *behind* a window,
/// at a caller-chosen radius — the tunable behind-window blur that `NSVisualEffectView` wraps but
/// doesn't expose (there only a fixed-radius material is selectable). A raw `CABackdropLayer` can't
/// do this: it only captures content *within* its own window. No SIP — these are ordinary (if
/// unpublished) CoreGraphics/SkyLight symbols that translucent HUDs have used for years.
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
func CGSSetWindowBackgroundBlurRadius(_ connection: Int32, _ window: Int32, _ radius: Int32) -> Int32

/// Blur whatever is behind `window` (an `NSWindow.windowNumber`) at `radius`, or remove the blur with
/// `radius == 0`. Best-effort: a non-zero `CGError` is ignored (the overlay still works unblurred).
func setWindowBackgroundBlur(window number: Int, radius: Int) {
    guard number != 0 else { return }
    _ = CGSSetWindowBackgroundBlurRadius(CGSMainConnectionID(), Int32(number), Int32(radius))
}

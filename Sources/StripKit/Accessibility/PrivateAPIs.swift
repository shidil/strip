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

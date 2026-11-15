import ApplicationServices
import CoreGraphics
import Foundation

/// `_AXUIElementGetWindow` maps an `AXUIElement` to its `CGWindowID`. Despite the leading
/// underscore it is **not** a SIP-gated symbol — it runs from a normally-signed process with only
/// the Accessibility grant, and every no-SIP window manager (Amethyst, AeroSpace, rift, OmniWM)
/// relies on it for a stable per-window identity. We use it purely for identity, never to move
/// windows (moves go through the public `kAXPosition`/`kAXSize` API in `AXWindow`).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Returns the `CGWindowID` for an accessibility window element, or `nil` if unavailable.
///
/// Cached per element (`WindowIDCache`): `_AXUIElementGetWindow` is a round trip to the window's
/// app, and the observer asks for it on every `kAXMoved`/`kAXResized` that Strip's own frame writes
/// cause, on main. The step 3 host trace measured 9.3 s of a 16 s trade/promote run inside it, with
/// single calls up to 419 ms when the app was busy. A window's id never changes, so only the first
/// lookup per element pays; the signpost times those misses.
func axWindowID(_ element: AXUIElement) -> CGWindowID? {
    if let id = WindowIDCache.shared.id(of: element) { return id }
    let sp = Signpost.log.beginInterval("axWindowID")
    defer { Signpost.log.endInterval("axWindowID", sp) }
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &wid) == .success else { return nil }
    WindowIDCache.shared.remember(wid, for: element)
    return wid
}

/// Window ids by AX element. Elements compare and hash locally (`CFEqual`/`CFHash`, no IPC), and
/// the element a notification delivers equals the one Strip registered. Thread-safe: the AX queues
/// and the tab scanner look ids up off main. An element is forgotten when its window is destroyed
/// (`WindowObserver`) and every element of an app that quits is too, so an app reusing an element
/// can't inherit a stale id. The whole cache is dropped past `limit` entries, so it can't grow
/// without bound.
final class WindowIDCache {
    static let shared = WindowIDCache()
    static let limit = 1024

    private var ids: [AXUIElement: CGWindowID] = [:]
    private let lock = NSLock()

    func id(of element: AXUIElement) -> CGWindowID? {
        lock.lock(); defer { lock.unlock() }
        return ids[element]
    }

    func remember(_ id: CGWindowID, for element: AXUIElement) {
        lock.lock(); defer { lock.unlock() }
        if ids.count >= Self.limit { ids.removeAll(keepingCapacity: true) }
        ids[element] = id
    }

    func forget(_ element: AXUIElement) {
        lock.lock(); defer { lock.unlock() }
        ids[element] = nil
    }

    /// Forget every element of app `pid` (it quit). `AXUIElementGetPid` is a local call.
    func forget(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        ids = ids.filter { element, _ in
            var p: pid_t = 0
            return AXUIElementGetPid(element, &p) != .success || p != pid
        }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return ids.count
    }
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

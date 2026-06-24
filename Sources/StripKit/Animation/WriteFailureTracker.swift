import ApplicationServices
import CoreGraphics

/// Decides when a window's Accessibility element is **dead** and should be dropped from the strip,
/// based on the results of the animator's frame writes (M7 AX-drop recovery).
///
/// The point is to distinguish a real death — a stale element after an app relaunch/crash, which
/// would otherwise wedge a phantom window into a slot forever — from a transient hiccup (`.
/// cannotComplete` under load), which a live window recovers from within a frame or two. So a
/// destroyed element (`.invalidUIElement`) is fatal immediately, while softer failures must repeat
/// `threshold` times *in a row*; any success resets the count.
///
/// Pure value type (no AX side effects), so the policy is unit-testable without real windows.
struct WriteFailureTracker {
    /// Consecutive non-success writes per window since its last success.
    private var counts: [CGWindowID: Int] = [:]
    /// Consecutive soft failures that mark a window dead. ~3 covers a real death within a single
    /// animation while tolerating the odd dropped write a live window shrugs off.
    let threshold: Int

    init(threshold: Int = 3) { self.threshold = threshold }

    /// Record one write's result for `id`. Returns true the moment the window should be considered
    /// lost (and the caller should drop it). After returning true, call `forget(_:)`.
    mutating func record(_ id: CGWindowID, error: AXError) -> Bool {
        if error == .success { counts[id] = 0; return false }
        if error == .invalidUIElement { counts[id] = threshold; return true } // destroyed → drop now
        let n = (counts[id] ?? 0) + 1
        counts[id] = n
        return n >= threshold
    }

    /// Forget a window's history (after dropping it, or when it leaves the animator).
    mutating func forget(_ id: CGWindowID) { counts[id] = nil }
}

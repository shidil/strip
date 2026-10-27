import AppKit
import SwiftUI

/// Holds the latest captured window thumbnails for the Overview, keyed by `CGWindowID`, and
/// publishes changes so the SwiftUI cards update reactively as async captures land — without the
/// `OverlayController` having to rebuild the hosting view.
///
/// `refresh()` captures on demand (when the overview opens) and **merges** results into the existing
/// map rather than replacing it, so a window that momentarily fails to capture keeps its previous
/// thumbnail as an instant first paint on reopen instead of flashing back to the placeholder.
///
/// Not `@MainActor`-isolated (so the non-isolated `OverlayController` can call it directly in Swift 5
/// mode); instead it hops to the main thread itself before touching `@Published` state, matching the
/// overlay layer's existing manual-dispatch style.
final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [CGWindowID: CGImage] = [:]

    /// The retina scale captures are taken at; the views render with the same scale so images aren't
    /// drawn double-size.
    static let scale = 2

    private var inFlight = false

    subscript(id: CGWindowID) -> CGImage? { images[id] }

    /// Re-capture one window right now, outside the `refresh` in-flight gate (tab peek needs the
    /// capture that follows *its* press, not to be dropped behind an Overview-open batch). Replaces
    /// that window's image on success; `completion(success)` fires on main.
    func captureNow(_ id: CGWindowID, pointSize: CGSize, completion: @escaping (Bool) -> Void = { _ in }) {
        Task { [weak self] in
            let captured = await WindowThumbnailer.capture(ids: [id], pointSize: pointSize, scale: Self.scale)
            await MainActor.run { [weak self] in
                if let image = captured[id] { self?.images[id] = image }
                completion(captured[id] != nil)
            }
        }
    }

    /// Capture thumbnails for `ids` and merge them into `images`. No-op while a capture is in flight,
    /// so rapid reopens don't stack overlapping ScreenCaptureKit passes. Call on the main thread.
    ///
    /// `evictOthers` (default `true`, the Overview behavior) drops any cached image whose id isn't in
    /// `ids` — correct when `ids` is the *complete* current set (e.g. the whole ring). A caller
    /// capturing a single window in isolation (e.g. a rail hover preview) must pass `false`, or it
    /// would wipe every other window's cached thumbnail on each hover.
    func refresh(ids: [CGWindowID], pointSize: CGSize, evictOthers: Bool = true) {
        guard !inFlight else { return }
        inFlight = true
        Task { [weak self] in
            let captured = await WindowThumbnailer.capture(ids: ids, pointSize: pointSize, scale: Self.scale)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Merge: keep stale images for ids still present that failed this pass; drop the rest
                // (unless `evictOthers` is false, in which case nothing outside `ids` is touched).
                var merged = evictOthers ? self.images.filter { ids.contains($0.key) } : self.images
                for (id, image) in captured { merged[id] = image }
                self.images = merged
                self.inFlight = false
            }
        }
    }
}

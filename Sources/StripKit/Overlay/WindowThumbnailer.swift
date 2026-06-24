import CoreGraphics
import ScreenCaptureKit

/// Captures still thumbnails of real on-screen windows for the Overview cards, via ScreenCaptureKit.
///
/// We key off `CGWindowID` — the same identity Strip already derives from `_AXUIElementGetWindow`
/// (`PrivateAPIs.swift`) — which equals `SCWindow.windowID`. `SCContentFilter(desktopIndependentWindow:)`
/// captures a window's *own* content even when it's occluded by others (the key win over the
/// obsoleted `CGWindowListCreateImage`), so a window buried in the strip still renders correctly.
///
/// Screen Recording is a **second TCC grant** (`kTCCServiceScreenCapture`), separate from
/// Accessibility. Like Accessibility it attributes to the *launching* process, so the existing
/// `make open` (LaunchServices) + stable signing already covers it. No Info.plist key is needed.
enum WindowThumbnailer {
    /// Whether Screen Recording is currently authorized — checked WITHOUT triggering the prompt.
    static func screenRecordingAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Explicitly request Screen Recording, registering Strip in System Settings and prompting once.
    /// (Merely touching `SCShareableContent` would also prompt, but this gives a deterministic ask
    /// up front instead of ambushing the user mid-capture.)
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Capture a still `CGImage` for each window id, sized for an overview card. One shared
    /// `SCShareableContent.current` (the expensive call) is fetched once and matched against every id;
    /// each window is captured concurrently. Windows that aren't shareable (gone / minimized / fully
    /// off-screen) simply don't appear in the result → the card falls back to its gradient placeholder.
    static func capture(ids: [CGWindowID], pointSize: CGSize, scale: Int) async -> [CGWindowID: CGImage] {
        guard !ids.isEmpty else { return [:] }
        guard let shareable = try? await SCShareableContent.current else { return [:] }

        // Index the shareable windows we care about by their CGWindowID.
        let wanted = Set(ids)
        let windows = shareable.windows.filter { wanted.contains($0.windowID) }
        guard !windows.isEmpty else { return [:] }

        let pixelWidth = Int(pointSize.width) * scale
        let pixelHeight = Int(pointSize.height) * scale

        return await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for window in windows {
                group.addTask {
                    (window.windowID, try? await captureOne(window, width: pixelWidth, height: pixelHeight))
                }
            }
            var out: [CGWindowID: CGImage] = [:]
            for await (id, image) in group {
                if let image { out[id] = image }
            }
            return out
        }
    }

    /// Capture one window into a `width × height` pixel buffer, fit (letterboxed) without stretching.
    private static func captureOne(_ window: SCWindow, width: Int, height: Int) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.scalesToFit = true               // fit the window into the box, no stretch
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true  // drop the drop-shadow alpha halo
        config.ignoreGlobalClipSingleWindow = true // capture full content even if clipped by a screen edge
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

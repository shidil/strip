import AppKit
import ApplicationServices

/// Enumerates and identifies the real, standard application windows on a given display using the
/// public Accessibility API only. This is the *snapshot* side; live create/destroy/focus
/// observation that drives auto-re-tiling lives in `WindowObserver` (M6).
public final class AccessibilityService {
    public init() {}

    // MARK: - Immutable-attribute caches (perf 2.5a)

    /// Per-window AX attributes that never change for an element's lifetime, memoized so a repeated
    /// enumeration scan doesn't re-pay their IPC. `role`/`subrole`/resizability are immutable;
    /// `frame` and `isMinimized` are deliberately NOT cached — they're mutable and, off-Space, AX
    /// returns stale/zero geometry, so they must be read live every scan. Keyed by the AX element;
    /// pruned to the windows actually seen each scan so closed windows don't leak.
    private let roleCache = AXAttrCache<AXElementKey, String?>()
    private let subroleCache = AXAttrCache<AXElementKey, String?>()
    private let resizableCache = AXAttrCache<AXElementKey, Bool>()

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

    /// Every window id the *window server* currently knows about, across all apps, layers and
    /// displays (minimized and off-Space windows included). This is a single cheap CoreGraphics call
    /// — no AX IPC — and, unlike the flaky `kAXWindows` enumeration, it's authoritative about
    /// liveness: a closed window's id is gone from this set. `refresh()` uses it to tell a genuinely
    /// closed ring window (drop it) from one a busy app merely omitted from an AX scan (keep it),
    /// so stale AX elements can't accumulate as off-screen ghosts.
    public func liveWindowIDs() -> Set<CGWindowID> {
        let opts: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids = Set<CGWindowID>()
        for w in info {
            if let n = w[kCGWindowNumber as String] as? CGWindowID { ids.insert(n) }
        }
        return ids
    }

    /// All managed standard windows across every running regular app, on every display.
    public func allWindows() -> [ManagedWindow] {
        let sp = Signpost.log
        let state = sp.beginInterval("allWindows")
        var result: [ManagedWindow] = []
        var scannedApps = 0
        var seen = Set<AXElementKey>()
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            scannedApps += 1
            result.append(contentsOf: windows(for: app, seen: &seen))
        }
        // Drop cache entries for windows that have gone away (perf 2.5a) so the immutable-attr caches
        // track the live window set rather than growing without bound.
        roleCache.retain(seen)
        subroleCache.retain(seen)
        resizableCache.retain(seen)
        // Integer interpolation only — non-allocating; quantifies the R1 enumeration cost.
        sp.endInterval("allWindows", state, "apps=\(scannedApps) windows=\(result.count)")
        return result
    }

    private func windows(for app: NSRunningApplication, seen: inout Set<AXElementKey>) -> [ManagedWindow] {
        let pid = app.processIdentifier
        guard pid > 0 else { return [] }
        let appElement = AXUIElementCreateApplication(pid)

        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let elements = ref as? [AXUIElement] else { return [] }

        let appName = app.localizedName ?? "App"
        let accentKey = app.bundleIdentifier ?? appName

        return elements.compactMap { element -> ManagedWindow? in
            seen.insert(AXElementKey(element))
            let w = AXWindow(element: element, pid: pid)
            // `frame` is two AX IPC round-trips (position + size) and is uncached; classify reads it
            // and hands it back so we don't read it a second time here (perf 1.3 — halves the frame
            // IPC per managed window per scan, the dominant cost in `allWindows`). The immutable
            // role/subrole/resizable reads are served from the caches above (perf 2.5a).
            let (cls, frame) = classifyWithFrame(w)
            guard cls == .managed, let frame, let id = axWindowID(element) else { return nil }
            return ManagedWindow(
                id: id, ax: w, appName: appName, accentKey: accentKey,
                title: w.title ?? appName, frame: frame
            )
        }
    }

    /// How Strip should treat a window. Only `.managed` windows are tiled; `.floating` windows are
    /// real app windows we deliberately leave where they are (dialogs, palettes, non-resizable
    /// windows); `.ignored` are not windows we'd ever consider (wrong role, minimized, too small).
    ///
    /// The split between `.floating` and `.ignored` doesn't change M6 behavior — both are simply
    /// left alone — but it names the distinction the M7 "respect user drags" / ignore-rules work
    /// will build on.
    public enum WindowClassification { case managed, floating, ignored }

    /// Conservative classifier (M6): tile only clearly-standard, resizable, usable-size windows;
    /// float the clear-cut leave-alone cases (sheets/dialogs/panels, non-resizable). No per-app
    /// denylist yet — that arrives with the config file in M9. Uncached — for external/diagnostic
    /// use, off the enumeration hot path; the cached `classifyWithFrame` is what `allWindows` uses.
    public static func classify(_ w: AXWindow) -> WindowClassification {
        Self.classifyGates(role: { w.role }, isMinimized: { w.isMinimized }, frame: { w.frame },
                           subrole: { w.subrole }, resizable: { w.isResizable }).classification
    }

    /// Classify `w` and return the frame read while doing so, so a caller that also needs the frame
    /// (the enumeration hot path) doesn't pay a second `kAXPosition`+`kAXSize` round-trip (perf 1.3).
    /// The immutable role/subrole/resizable reads are routed through the per-element caches (perf
    /// 2.5a); `frame`/`isMinimized` stay live. Each read is still gated lazily — a non-window or
    /// minimized element pays no extra IPC, and the gate order is identical to before. `frame` is
    /// nil when not (yet) read.
    func classifyWithFrame(_ w: AXWindow) -> (classification: WindowClassification, frame: CGRect?) {
        let key = AXElementKey(w.element)
        return Self.classifyGates(
            role: { self.roleCache.value(for: key) { w.role } },
            isMinimized: { w.isMinimized },
            frame: { w.frame },
            subrole: { self.subroleCache.value(for: key) { w.subrole } },
            resizable: { self.resizableCache.value(for: key) { w.isResizable } }
        )
    }

    /// Pure gate logic shared by the cached (hot-path) and uncached classifiers. Reads are passed as
    /// lazy closures so each is evaluated only when its gate is reached — preserving the exact lazy
    /// IPC order — while the caller decides which reads are cached vs. live.
    private static func classifyGates(
        role: () -> String?, isMinimized: () -> Bool, frame: () -> CGRect?,
        subrole: () -> String?, resizable: () -> Bool
    ) -> (classification: WindowClassification, frame: CGRect?) {
        guard role() == (kAXWindowRole as String) else { return (.ignored, nil) }
        if isMinimized() { return (.ignored, nil) }
        let f = frame()
        guard let rect = f, rect.width >= 80, rect.height >= 80 else { return (.ignored, f) }
        // Anything that isn't a plain standard window — dialogs, sheets, system dialogs, floating
        // panels, palettes, unknown subroles — is left in place. (Some apps report no subrole for
        // their main window; allow that as standard.)
        if let sub = subrole(), sub != (kAXStandardWindowSubrole as String) { return (.floating, f) }
        // A window we can't resize can't be tiled sensibly — leave it where the app put it.
        if !resizable() { return (.floating, f) }
        return (.managed, f)
    }
}

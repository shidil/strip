import AppKit

/// A real application window that Strip is managing, with a stable identity.
public struct ManagedWindow: Identifiable {
    /// Stable identity for the lifetime of the window (`CGWindowID` from `_AXUIElementGetWindow`).
    public let id: CGWindowID
    public let ax: AXWindow
    /// Owning app's localized name (e.g. "Safari").
    public let appName: String
    /// Stable key used to derive a deterministic accent color (bundle id, falling back to name).
    public let accentKey: String
    /// Last-known window title.
    public var title: String
    /// Last-known frame in Quartz global coordinates (top-left origin).
    public var frame: CGRect

    public var accent: NSColor { Theme.accent(for: accentKey) }
    public var letter: String { Theme.letter(for: appName) }
    /// The owning app's real icon, for the rail chip. `nil` falls back to the letter chip (e.g. the
    /// app already quit but its window lingers, or a headless/test context with no running app).
    public var icon: NSImage? { NSRunningApplication(processIdentifier: ax.pid)?.icon }

    public init(id: CGWindowID, ax: AXWindow, appName: String, accentKey: String, title: String, frame: CGRect) {
        self.id = id
        self.ax = ax
        self.appName = appName
        self.accentKey = accentKey
        self.title = title
        self.frame = frame
    }
}

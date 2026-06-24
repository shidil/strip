import AppKit

/// One chip in the film rail. Mirrors the prototype's `rail` items
/// (`Strip Window Manager.dc.html`, lines 269-278).
public struct RailItem: Identifiable {
    public let id: CGWindowID
    /// Single-character app chip (`Theme.letter`).
    public let letter: String
    /// Owning app's localized name — shown on the overview card.
    public let appName: String
    /// Last-known window title — shown on the overview card.
    public let title: String
    /// Deterministic per-app accent (`Theme.accent`).
    public let accent: NSColor
    /// Occupies a currently-visible slot → full opacity (otherwise dimmed).
    public let assigned: Bool
    /// The window in the focused slot → white outline.
    public let active: Bool
    /// Pinned → gold pin dot.
    public let pinned: Bool
    /// Window aspect ratio (width / height), used to size the overview card so its thumbnail needs
    /// no letterbox bars. The view clamps it to a sane range.
    public let aspect: CGFloat

    public init(id: CGWindowID, letter: String, appName: String, title: String, accent: NSColor,
                assigned: Bool, active: Bool, pinned: Bool, aspect: CGFloat) {
        self.id = id
        self.letter = letter
        self.appName = appName
        self.title = title
        self.accent = accent
        self.assigned = assigned
        self.active = active
        self.pinned = pinned
        self.aspect = aspect
    }
}

/// Everything the overlay chrome needs to render one pass. The controller emits this after every
/// `apply()`; M4 consumes it to draw the film rail and the status pill.
public struct OverlaySnapshot {
    public let rail: [RailItem]
    /// The active display the chrome should anchor to.
    public let screen: NSScreen

    // Status-pill labels (prototype top bar lines 23-38; computed like `modeLabel`/`transLabel`/
    // `layoutLabel`, lines 290-293).
    /// Name of the app whose window is in the focused slot.
    public let activeApp: String
    /// Accent of the focused window — used to tint the focus ring.
    public let activeAccent: NSColor?
    /// e.g. "Monocle", "3‑up · focus".
    public let layoutLabel: String
    /// Pin posture: "Strip shift" (no pins) / "Hybrid" (some) / "Independent" (all slots pinned).
    public let modeLabel: String
    /// Current spring feel ("Track" / "Pop" / "Glide").
    public let transLabel: String
    /// Wall-clock "h:mm" (refreshed on each render).
    public let clock: String

    public init(rail: [RailItem], screen: NSScreen, activeApp: String, activeAccent: NSColor?,
                layoutLabel: String, modeLabel: String, transLabel: String, clock: String) {
        self.rail = rail
        self.screen = screen
        self.activeApp = activeApp
        self.activeAccent = activeAccent
        self.layoutLabel = layoutLabel
        self.modeLabel = modeLabel
        self.transLabel = transLabel
        self.clock = clock
    }
}

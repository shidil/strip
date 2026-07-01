import AppKit
import SwiftUI

/// One chip in the film rail. Mirrors the prototype's `rail` items
/// (`Strip Window Manager.dc.html`, lines 269-278).
public struct RailItem: Identifiable, Equatable {
    public let id: CGWindowID
    /// Single-character app chip (`Theme.letter`).
    public let letter: String
    /// Owning app's localized name — shown on the overview card.
    public let appName: String
    /// Last-known window title — shown on the overview card.
    public let title: String
    /// Deterministic per-app accent (`Theme.accent`).
    public let accent: NSColor
    /// The owning app's real icon (`ManagedWindow.icon`); `nil` falls back to `letter`.
    public let icon: NSImage?
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
                icon: NSImage?, assigned: Bool, active: Bool, pinned: Bool, aspect: CGFloat) {
        self.id = id
        self.letter = letter
        self.appName = appName
        self.title = title
        self.accent = accent
        self.icon = icon
        self.assigned = assigned
        self.active = active
        self.pinned = pinned
        self.aspect = aspect
    }

    /// `accent`/`icon` are class types so equality can't be auto-synthesized — compare via `isEqual`.
    /// Drives the overlay's skip-when-unchanged pre-filter (don't invalidate SwiftUI when the rail is
    /// identical, e.g. a spring-cycle re-apply).
    public static func == (lhs: RailItem, rhs: RailItem) -> Bool {
        lhs.id == rhs.id && lhs.letter == rhs.letter && lhs.appName == rhs.appName
            && lhs.title == rhs.title && lhs.accent.isEqual(rhs.accent)
            && ((lhs.icon == nil && rhs.icon == nil) || (lhs.icon?.isEqual(rhs.icon) ?? false))
            && lhs.assigned == rhs.assigned && lhs.active == rhs.active && lhs.pinned == rhs.pinned
            && lhs.aspect == rhs.aspect
    }
}

/// The status pill's render-affecting strings, pulled out of `OverlaySnapshot` so the pill view can
/// observe just these and skip re-rendering when they're unchanged (e.g. `clock` is "h:mm", so the
/// pill doesn't churn every apply). Deliberately excludes `screen`/`NSColor` (not rendered as text).
public struct StatusFields: Equatable {
    public let activeApp: String
    public let layoutLabel: String
    public let modeLabel: String
    public let transLabel: String
    public let clock: String

    public init(_ s: OverlaySnapshot) {
        activeApp = s.activeApp
        layoutLabel = s.layoutLabel
        modeLabel = s.modeLabel
        transLabel = s.transLabel
        clock = s.clock
    }

    public init(activeApp: String = "", layoutLabel: String = "", modeLabel: String = "",
                transLabel: String = "", clock: String = "") {
        self.activeApp = activeApp
        self.layoutLabel = layoutLabel
        self.modeLabel = modeLabel
        self.transLabel = transLabel
        self.clock = clock
    }

    /// Placeholder for the model's initial state before the first render.
    public static let empty = StatusFields()
}

/// Stable, observable backing store for the overlay's SwiftUI views. The hosting `rootView`s are set
/// once (see `OverlayController.init`); each render mutates these `@Published` fields so SwiftUI diffs
/// incrementally instead of rebuilding the whole tree — the lever that keeps the overlay render off
/// the animation's critical path. Mirrors the `ThumbnailStore`/`OverviewSelection` pattern.
public final class OverlayModel: ObservableObject {
    @Published public var rail: [RailItem]
    @Published public var status: StatusFields
    @Published public var railEdge: RailEdge

    public init(rail: [RailItem], status: StatusFields, railEdge: RailEdge = .default) {
        self.rail = rail
        self.status = status
        self.railEdge = railEdge
    }
}

/// Whether the rail panel needs a re-fit + reposition. The rail is center-anchored and constant-width
/// during a slide (fixed-size chips, constant count), so only a change in chip count moves its frame;
/// a moving `active` highlight repaints inside the existing frame. (Screen changes are handled
/// separately by identity at the call site.) Pure so it's unit-testable without AppKit.
public func railNeedsRefit(oldCount: Int, newCount: Int) -> Bool { oldCount != newCount }

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
    /// Which screen edge the film rail is anchored to.
    public let railEdge: RailEdge

    public init(rail: [RailItem], screen: NSScreen, activeApp: String, activeAccent: NSColor?,
                layoutLabel: String, modeLabel: String, transLabel: String, clock: String,
                railEdge: RailEdge) {
        self.rail = rail
        self.screen = screen
        self.activeApp = activeApp
        self.activeAccent = activeAccent
        self.layoutLabel = layoutLabel
        self.modeLabel = modeLabel
        self.transLabel = transLabel
        self.clock = clock
        self.railEdge = railEdge
    }
}

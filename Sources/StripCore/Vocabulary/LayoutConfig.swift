import CoreGraphics

/// Tunable window-sizing knobs for the strip. The geometry engine (`SlotGeometry`) computes every
/// slot rect from these, so the strip **fills the active display** instead of inheriting the
/// prototype's fixed 1440×900 stage proportions (which left big wallpaper margins on a real ultrawide).
/// All values are points within the display's visible frame.
public struct LayoutConfig: Equatable, Codable {
    /// Gap between the windows and the edge of the visible frame.
    public var outerPadding: CGFloat
    /// Gap between adjacent windows.
    public var innerGap: CGFloat
    /// In `focus` emphasis, the emphasized window's share of the total window area (the remaining
    /// area is split equally among the other slots). Clamped to `focusRatioRange` at use.
    public var focusRatio: CGFloat
    /// In monocle (1-up), the single window's width as a fraction of the usable width, **centered**
    /// so there's wallpaper margin on both sides — a full-width window is too wide to use on an
    /// ultrawide. Push it to 1.0 for a "filled" monocle. Clamped to `monocleWidthRange` at use.
    public var monocleWidthFraction: CGFloat
    /// Every slotted window's height as a fraction of the usable height, **centered vertically** so
    /// there's margin top and bottom. 1.0 = full height (the default). Clamped to `heightRange`.
    public var heightFraction: CGFloat
    /// Where a freshly-opened window lands when Strip auto-absorbs it (M6 auto-react).
    public var newWindowPlacement: NewWindowPlacement

    public init(outerPadding: CGFloat = 8, innerGap: CGFloat = 8, focusRatio: CGFloat = 0.5,
                monocleWidthFraction: CGFloat = 0.6, heightFraction: CGFloat = 1.0,
                newWindowPlacement: NewWindowPlacement = .focusCenter) {
        self.outerPadding = outerPadding
        self.innerGap = innerGap
        self.focusRatio = focusRatio
        self.monocleWidthFraction = monocleWidthFraction
        self.heightFraction = heightFraction
        self.newWindowPlacement = newWindowPlacement
    }

    /// Decode tolerantly: any field missing from an older persisted blob falls back to its default,
    /// so adding a knob (like `newWindowPlacement`) never invalidates a user's saved settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LayoutConfig()
        outerPadding = try c.decodeIfPresent(CGFloat.self, forKey: .outerPadding) ?? d.outerPadding
        innerGap = try c.decodeIfPresent(CGFloat.self, forKey: .innerGap) ?? d.innerGap
        focusRatio = try c.decodeIfPresent(CGFloat.self, forKey: .focusRatio) ?? d.focusRatio
        monocleWidthFraction = try c.decodeIfPresent(CGFloat.self, forKey: .monocleWidthFraction) ?? d.monocleWidthFraction
        heightFraction = try c.decodeIfPresent(CGFloat.self, forKey: .heightFraction) ?? d.heightFraction
        newWindowPlacement = try c.decodeIfPresent(NewWindowPlacement.self, forKey: .newWindowPlacement) ?? d.newWindowPlacement
    }

    /// Space-filling default (full height + edge-to-edge width with small uniform gaps, center ~50%;
    /// monocle centered at ~60% width with margins).
    public static let `default` = LayoutConfig()

    /// Allowed range for `focusRatio`: the lower bound is ≈ equal thirds, the upper a dominant focus.
    public static let focusRatioRange: ClosedRange<CGFloat> = 0.34...0.85
    /// Allowed range for `monocleWidthFraction`: comfortable-and-centered up to fully filled.
    public static let monocleWidthRange: ClosedRange<CGFloat> = 0.35...1.0
    /// Allowed range for `heightFraction`: a usable minimum up to full height.
    public static let heightRange: ClosedRange<CGFloat> = 0.4...1.0

    /// `focusRatio` clamped to `focusRatioRange`.
    public var clampedFocusRatio: CGFloat {
        min(max(focusRatio, Self.focusRatioRange.lowerBound), Self.focusRatioRange.upperBound)
    }
    /// `monocleWidthFraction` clamped to `monocleWidthRange`.
    public var clampedMonocleWidth: CGFloat {
        min(max(monocleWidthFraction, Self.monocleWidthRange.lowerBound), Self.monocleWidthRange.upperBound)
    }
    /// `heightFraction` clamped to `heightRange`.
    public var clampedHeight: CGFloat {
        min(max(heightFraction, Self.heightRange.lowerBound), Self.heightRange.upperBound)
    }
}

/// What Strip does with a window the moment it appears (M6 auto-react).
public enum NewWindowPlacement: String, Codable {
    /// Slide the new window into the preferred unpinned slot — center, else right, else left — and
    /// give it keyboard focus. The niri-like "act on what you just opened" default.
    case focusCenter
    /// Tuck the new window at the end of the film, out of the way, without stealing focus.
    case append
}

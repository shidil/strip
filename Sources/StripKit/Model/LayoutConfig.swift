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

    public init(outerPadding: CGFloat = 8, innerGap: CGFloat = 8, focusRatio: CGFloat = 0.5,
                monocleWidthFraction: CGFloat = 0.6, heightFraction: CGFloat = 1.0) {
        self.outerPadding = outerPadding
        self.innerGap = innerGap
        self.focusRatio = focusRatio
        self.monocleWidthFraction = monocleWidthFraction
        self.heightFraction = heightFraction
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

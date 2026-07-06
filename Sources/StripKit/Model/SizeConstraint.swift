import CoreGraphics

/// A window's learned real-world size bounds — what the app itself will actually accept, discovered
/// at runtime from clamp events (`WindowAnimator.onFrameClamped`): when the settle read-back comes
/// back *larger* than requested the app has a hard minimum (AppKit `contentMinSize` — Console,
/// Activity Monitor), when it comes back *smaller* the app has a hard maximum (effectively
/// fixed-size windows — System Settings). There is no AX attribute exposing these, so learning from
/// clamps is the only general mechanism; probing `kAXSize` settability doesn't help (Settings
/// reports settable and then clamps every write).
///
/// Bounds are per-dimension and move monotonically — floors only ever rise, ceilings only ever
/// fall, each step by more than `learnThreshold`, and floors are capped at the screen's usable
/// size. That monotonicity is what makes feeding a learned constraint back into layout safe: the
/// re-apply targets sizes inside the bounds, so it cannot trigger a fresh clamp → learn → re-apply
/// cycle (the infinite-loop fear that kept `reconcileClampedFrame` from re-applying before this).
public struct SizeConstraint: Equatable {
    /// Learned floor (the app refuses to be smaller). `nil` until a grow-clamp teaches it.
    public var minWidth: CGFloat?
    public var minHeight: CGFloat?
    /// Learned ceiling (the app refuses to be larger). `nil` until a shrink-clamp teaches it.
    public var maxWidth: CGFloat?
    public var maxHeight: CGFloat?

    public init(minWidth: CGFloat? = nil, minHeight: CGFloat? = nil,
                maxWidth: CGFloat? = nil, maxHeight: CGFloat? = nil) {
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    /// Minimum meaningful clamp delta. Terminal/stepping apps settle a few px off from character-cell
    /// quantization and must not trigger constraint churn; kept well above the animator's
    /// `frameMatches` tolerance (1.5px) so every learned step is a real, intentional app clamp.
    public static let learnThreshold: CGFloat = 8

    /// Clamp a proposed width to the learned bounds. When a floor and ceiling cross (shouldn't
    /// happen — both move away from each other — but reads can be noisy), the floor wins:
    /// commanding at least the app's minimum is always achievable, commanding below it is not.
    public func clampedWidth(_ w: CGFloat) -> CGFloat {
        var v = w
        if let mx = maxWidth { v = min(v, mx) }
        if let mn = minWidth { v = max(v, mn) }
        return v
    }

    /// Clamp a proposed height to the learned bounds (floor wins over a crossed ceiling).
    public func clampedHeight(_ h: CGFloat) -> CGFloat {
        var v = h
        if let mx = maxHeight { v = min(v, mx) }
        if let mn = minHeight { v = max(v, mn) }
        return v
    }

    /// Clamp a proposed size to the learned bounds.
    public func clamped(_ s: CGSize) -> CGSize {
        CGSize(width: clampedWidth(s.width), height: clampedHeight(s.height))
    }

    /// One pure learning step from a clamp event. Returns the updated constraint **iff the clamp
    /// teaches something new**; `nil` means "nothing learned" and is the caller's signal not to
    /// re-apply — sub-threshold deltas (stepping apps), position-only mismatches (equal sizes), and
    /// clamps already explained by the current bounds all return `nil`, which is what guarantees the
    /// learn → re-apply loop terminates.
    ///
    /// Per dimension: `actual > requested + threshold` raises the floor to `actual` (capped at
    /// `bounds`, so a bad read-back can never learn an unsatisfiable floor); `actual < requested -
    /// threshold` lowers the ceiling to `actual`. Each bound only moves if it improves on the stored
    /// value by more than the threshold.
    public static func learned(from old: SizeConstraint?, requested: CGSize, actual: CGSize,
                               bounds: CGSize) -> SizeConstraint? {
        let t = learnThreshold
        var c = old ?? SizeConstraint()
        var changed = false

        func raiseFloor(_ floor: inout CGFloat?, achieved: CGFloat, asked: CGFloat, cap: CGFloat) {
            guard achieved > asked + t else { return }
            let new = min(achieved, cap)
            guard new > (floor ?? 0) + t else { return }
            floor = new
            changed = true
        }
        func lowerCeiling(_ ceiling: inout CGFloat?, achieved: CGFloat, asked: CGFloat) {
            guard achieved < asked - t else { return }
            guard achieved < (ceiling ?? .greatestFiniteMagnitude) - t else { return }
            ceiling = achieved
            changed = true
        }

        raiseFloor(&c.minWidth, achieved: actual.width, asked: requested.width, cap: bounds.width)
        raiseFloor(&c.minHeight, achieved: actual.height, asked: requested.height, cap: bounds.height)
        lowerCeiling(&c.maxWidth, achieved: actual.width, asked: requested.width)
        lowerCeiling(&c.maxHeight, achieved: actual.height, asked: requested.height)

        return changed ? c : nil
    }
}

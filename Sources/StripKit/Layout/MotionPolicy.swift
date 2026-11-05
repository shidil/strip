import CoreGraphics

/// Pure motion decisions — which moves must *snap* (one write, an instant cut) rather than spring.
/// Kept free of AppKit/AX so every rule is unit-testable (Seats & Pile design: "content changes cut,
/// position changes spring"; `docs/design/seats-and-pile.md`, slice 0).
public enum MotionPolicy {
    /// Fraction of the visible width, either side of its midline, treated as "the center". A window
    /// centered here (the C seat, a monocle window) parks one seat-width in either direction without
    /// crossing another seat, so it may still spring off either edge.
    static let centerBand: CGFloat = 0.1

    /// Whether springing a window from `from` to `to` would sweep it across the visible display.
    ///
    /// The wrapping ring decides a parked window's edge by its ring distance from the center, so a
    /// slide can flip a window from one park edge to the other, or pull it out of the park on the far
    /// side of its new seat (e.g. 2-up/monocle with 3 windows, 3-up with 4+). A spring then drags it
    /// through every seat in between — the distracting motion Strip exists to avoid. Such moves snap:
    ///
    /// - **off-screen → off-screen:** when the park edge flips (left ↔ right) — the spring would
    ///   travel through the whole display. A window staying on its edge (unchanged, or resized while
    ///   parked) is invisible either way and keeps its normal path;
    /// - **off-screen ↔ on-screen:** when the on-screen frame sits on the *opposite* half of the
    ///   display from the off-screen one (outside the center band) — it would cross the other seats;
    /// - **on-screen → on-screen:** never — slot-to-slot motion is the film's normal spring.
    ///
    /// "Off-screen" means on **no** display: a window sitting on another display is on-screen, not
    /// parked (`displays`, default just `vis`). An empty frame (AX reports zero geometry for windows
    /// on other Spaces) is never classified — no snap.
    ///
    /// All rects in Quartz global coordinates; `vis` is the strip display's visible frame.
    public static func sweepsAcross(from: CGRect, to: CGRect, in vis: CGRect,
                                    displays: [CGRect] = []) -> Bool {
        guard !from.isEmpty, !to.isEmpty else { return false }
        let screens = displays.isEmpty ? [vis] : displays
        func isOff(_ r: CGRect) -> Bool { !screens.contains { r.intersects($0) } }
        let fromOff = isOff(from)
        let toOff = isOff(to)
        switch (fromOff, toOff) {
        case (false, false):
            return false
        case (true, true):
            return (from.midX < vis.midX) != (to.midX < vis.midX) // park edge flips
        default:
            let off = fromOff ? from : to
            let on = fromOff ? to : from
            let offIsLeft = off.midX < vis.midX
            let band = vis.width * centerBand
            if abs(on.midX - vis.midX) <= band { return false } // centered → one seat of travel
            let onIsLeft = on.midX < vis.midX
            return onIsLeft != offIsLeft
        }
    }
}

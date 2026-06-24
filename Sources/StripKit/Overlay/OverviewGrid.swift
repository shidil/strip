import Foundation

/// A directional move of the keyboard selection inside the Overview grid.
public enum OverviewNav {
    case left, right, up, down
}

/// The next selected card index for a directional move within an Overview grid of `count` cards laid
/// out `perRow` per row. Movement **wraps** at every edge: left/right step ±1 along the flat ring,
/// up/down step ±`perRow` (a whole row). All arithmetic goes through `posMod` so it wraps cleanly
/// (the same positive-modulo the film ring uses).
///
/// Pure (no AppKit/SwiftUI), so the navigation math is unit-tested without a GUI — mirroring how the
/// `StripState` mutations are kept pure and tested.
public func nextOverviewIndex(from idx: Int, count: Int, perRow: Int, _ nav: OverviewNav) -> Int {
    guard count > 0 else { return 0 }
    guard perRow > 0 else { return posMod(idx, count) }
    let i = posMod(idx, count)
    switch nav {
    case .left:  return posMod(i - 1, count)
    case .right: return posMod(i + 1, count)
    case .up:    return posMod(i - perRow, count)
    case .down:  return posMod(i + perRow, count)
    }
}

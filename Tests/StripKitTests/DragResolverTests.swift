import XCTest
import CoreGraphics
@testable import StripKit

/// Respect-user-drags (M7 Slice 4): `DragResolver` must be the exact inverse of `SlotGeometry` for
/// the dominant slot, so a user resize maps cleanly back into the sizing knobs and re-applying
/// honors the new proportions instead of fighting the drag.
final class DragResolverTests: XCTestCase {
    // A realistic ultrawide visible frame (BenQ EX3415R), origin nonzero to catch origin bugs.
    let vis = CGRect(x: 0, y: 25, width: 3440, height: 1415)

    /// Feeding a slot rect straight back through the resolver should recover the config that produced
    /// it — the round-trip property that makes "keep the drag" stable.
    func assertRoundTrips(cols: Int, emphasis: Emphasis, focusSlot: Slot,
                          config: LayoutConfig, file: StaticString = #filePath, line: UInt = #line) {
        let rects = SlotGeometry.rects(cols: cols, emphasis: emphasis, focusSlot: focusSlot,
                                       in: vis, config: config)
        let dominant: Slot = cols == 2 ? focusSlot : .C
        guard let rect = rects[dominant] else {
            return XCTFail("no rect for dominant slot \(dominant)", file: file, line: line)
        }
        let out = DragResolver.resizeConfig(focusFrame: rect, vis: vis, cols: cols,
                                            emphasis: emphasis, base: config)
        XCTAssertEqual(out.heightFraction, config.heightFraction, accuracy: 0.001, file: file, line: line)
        if cols == 1 {
            XCTAssertEqual(out.monocleWidthFraction, config.monocleWidthFraction, accuracy: 0.001,
                           file: file, line: line)
        } else if emphasis == .focus {
            XCTAssertEqual(out.focusRatio, config.focusRatio, accuracy: 0.001, file: file, line: line)
        }
    }

    func testMonocleRoundTrips() {
        var c = LayoutConfig.default
        c.monocleWidthFraction = 0.72
        c.heightFraction = 0.8
        assertRoundTrips(cols: 1, emphasis: .focus, focusSlot: .C, config: c)
    }

    func testThreeUpFocusRoundTrips() {
        var c = LayoutConfig.default
        c.focusRatio = 0.62
        c.heightFraction = 0.9
        assertRoundTrips(cols: 3, emphasis: .focus, focusSlot: .C, config: c)
    }

    func testTwoUpFocusRoundTripsForFocusedSlot() {
        var c = LayoutConfig.default
        c.focusRatio = 0.7
        assertRoundTrips(cols: 2, emphasis: .focus, focusSlot: .L, config: c)
        assertRoundTrips(cols: 2, emphasis: .focus, focusSlot: .R, config: c)
    }

    /// Widening the dominant window past the slot's current width raises `focusRatio`.
    func testWiderResizeRaisesFocusRatio() {
        var c = LayoutConfig.default
        c.focusRatio = 0.5
        let rects = SlotGeometry.rects(cols: 3, emphasis: .focus, focusSlot: .C, in: vis, config: c)
        var wider = rects[.C]!
        wider.size.width += 400
        let out = DragResolver.resizeConfig(focusFrame: wider, vis: vis, cols: 3,
                                            emphasis: .focus, base: c)
        XCTAssertGreaterThan(out.focusRatio, 0.5)
    }

    /// A shorter drag lowers `heightFraction`, and the value is clamped to the usable range.
    func testHeightIsHonoredAndClamped() {
        let c = LayoutConfig.default // heightFraction 1.0
        var tiny = SlotGeometry.rects(cols: 3, emphasis: .focus, focusSlot: .C, in: vis, config: c)[.C]!
        tiny.size.height = 10 // absurdly short → below the floor
        let out = DragResolver.resizeConfig(focusFrame: tiny, vis: vis, cols: 3,
                                            emphasis: .focus, base: c)
        XCTAssertEqual(out.heightFraction, LayoutConfig.heightRange.lowerBound, accuracy: 0.001)
    }

    /// Equal emphasis has no width knob; width must be left untouched (it snaps back on re-apply).
    func testEqualEmphasisLeavesWidthUntouched() {
        var c = LayoutConfig.default
        c.focusRatio = 0.5
        let rects = SlotGeometry.rects(cols: 3, emphasis: .equal, focusSlot: .C, in: vis, config: c)
        var wider = rects[.C]!
        wider.size.width += 500
        let out = DragResolver.resizeConfig(focusFrame: wider, vis: vis, cols: 3,
                                            emphasis: .equal, base: c)
        XCTAssertEqual(out.focusRatio, 0.5, accuracy: 0.001, "equal emphasis must not move focusRatio")
    }
}

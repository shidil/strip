import XCTest
import CoreGraphics
@testable import StripKit

final class StripLayoutTests: XCTestCase {
    let ring: [CGWindowID] = [1, 2, 3, 4, 5, 6, 7]
    // A generic visible frame for slot-assignment tests (geometry now fills whatever frame it's given).
    let stageVis = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func assignment(_ s: StripState) -> [Slot: CGWindowID] {
        StripLayout(s).assignment()
    }

    // MARK: - Ring rotation / slot assignment

    func testThreeUpCentersFocusWithNeighbors() {
        let s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus)
        let a = assignment(s)
        XCTAssertEqual(a[.C], 3, "center slot holds centerId")
        XCTAssertEqual(a[.L], 2, "left neighbor")
        XCTAssertEqual(a[.R], 4, "right neighbor")
    }

    func testRotatingCenterShiftsTheFilm() {
        let a = assignment(StripState(ring: ring, centerId: 4, cols: 3, emphasis: .focus))
        XCTAssertEqual(a[.L], 3)
        XCTAssertEqual(a[.C], 4)
        XCTAssertEqual(a[.R], 5)
    }

    func testRingWrapsAround() {
        // centerId = first element → left neighbor wraps to the last element.
        let a = assignment(StripState(ring: ring, centerId: 1, cols: 3, emphasis: .focus))
        XCTAssertEqual(a[.L], 7)
        XCTAssertEqual(a[.C], 1)
        XCTAssertEqual(a[.R], 2)
    }

    func testMonocleAssignsOnlyCenter() {
        let a = assignment(StripState(ring: ring, centerId: 5, cols: 1))
        XCTAssertEqual(a[.C], 5)
        XCTAssertNil(a[.L])
        XCTAssertNil(a[.R])
    }

    func testTwoUpPrimaryIsLeft() {
        // For 2-up the anchor (primary) slot is L, so centerId lands left.
        let a = assignment(StripState(ring: ring, centerId: 3, cols: 2, focusSlot: .L))
        XCTAssertEqual(a[.L], 3)
        XCTAssertEqual(a[.R], 4)
    }

    // MARK: - Pinning

    func testPinnedSlotHoldsItsWindowWhileOthersFlow() {
        let s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus,
                           pins: [.L: 7], focusSlot: .C)
        let a = assignment(s)
        XCTAssertEqual(a[.L], 7, "pinned window stays in L")
        XCTAssertEqual(a[.C], 3, "center still centered among unpinned")
        XCTAssertEqual(a[.R], 4)
    }

    func testPinnedWindowExcludedFromFlow() {
        // Pinning the centerId forces the center to fall back to the first unpinned window.
        let s = StripState(ring: ring, centerId: 1, cols: 3, emphasis: .focus, pins: [.R: 1])
        let a = assignment(s)
        XCTAssertEqual(a[.R], 1)
        XCTAssertNotEqual(a[.C], 1)
    }

    // MARK: - activeId

    func testActiveIdFollowsFocusSlot() {
        let s = StripState(ring: ring, centerId: 3, cols: 3, focusSlot: .R)
        XCTAssertEqual(StripLayout(s).activeId, 4, "focus on R → active is the R window")
    }

    func testFocusSlotMayRestOnAPinnedSlot() {
        // Focus pointed at a pinned slot must resolve to the pinned window (not get clamped off it),
        // so the focus ring keeps tracking a pinned, focused window.
        let s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus,
                           pins: [.L: 7], focusSlot: .L)
        XCTAssertEqual(StripLayout(s).activeId, 7, "focus on a pinned slot resolves to the pinned window")
    }

    // MARK: - Space-filling geometry (windows fill the visible frame; sizes driven by LayoutConfig)

    /// Default config on an ultrawide: windows fill the full usable height and span edge-to-edge.
    func testThreeUpFocusFillsTheVisibleFrame() {
        let vis = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let cfg = LayoutConfig.default // pad 8, gap 8, focusRatio 0.5
        let s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, config: cfg)
        let p = StripLayout(s).placements(in: vis)
        let l = p.first { $0.id == 2 }!, c = p.first { $0.id == 3 }!, r = p.first { $0.id == 4 }!

        // Full-height fill: every slotted window is the full usable height, vertically padded.
        let usableH = vis.height - 2 * cfg.outerPadding
        for w in [l, c, r] {
            XCTAssertEqual(w.frame.height, usableH, accuracy: 0.01, "windows fill the height")
            XCTAssertEqual(w.frame.minY, vis.minY + cfg.outerPadding, accuracy: 0.01)
        }
        // Edge-to-edge width: left edge at the padding, right edge at width − padding.
        XCTAssertEqual(l.frame.minX, vis.minX + cfg.outerPadding, accuracy: 0.01)
        XCTAssertEqual(r.frame.maxX, vis.maxX - cfg.outerPadding, accuracy: 0.01)

        // Center gets focusRatio of the window area; neighbors split the rest equally.
        let usableW = vis.width - 2 * cfg.outerPadding
        let windowArea = usableW - 2 * cfg.innerGap
        XCTAssertEqual(c.frame.width, 0.5 * windowArea, accuracy: 0.01)
        XCTAssertEqual(l.frame.width, 0.25 * windowArea, accuracy: 0.01)
        XCTAssertEqual(r.frame.width, l.frame.width, accuracy: 0.01, "neighbors are equal")
        XCTAssertEqual(c.frame.midX, vis.midX, accuracy: 0.5, "center stays centered")
        XCTAssertTrue(c.active)
        XCTAssertEqual(c.slot, .C)
    }

    /// A larger focusRatio widens the center window (and shrinks the neighbors).
    func testFocusRatioWidensTheCenter() {
        let vis = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        func centerWidth(_ ratio: CGFloat) -> CGFloat {
            let cfg = LayoutConfig(focusRatio: ratio)
            let s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, config: cfg)
            return StripLayout(s).placements(in: vis).first { $0.id == 3 }!.frame.width
        }
        XCTAssertGreaterThan(centerWidth(0.7), centerWidth(0.4))
    }

    /// Equal emphasis fills the width with three equal-width windows (focusRatio ignored).
    func testEqualEmphasisFillsWidthEqually() {
        let vis = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let cfg = LayoutConfig.default
        let s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .equal, config: cfg)
        let p = StripLayout(s).placements(in: vis)
        let l = p.first { $0.id == 2 }!, c = p.first { $0.id == 3 }!, r = p.first { $0.id == 4 }!
        let windowArea = (vis.width - 2 * cfg.outerPadding) - 2 * cfg.innerGap
        for w in [l, c, r] { XCTAssertEqual(w.frame.width, windowArea / 3, accuracy: 0.01) }
        XCTAssertEqual(l.frame.minX, vis.minX + cfg.outerPadding, accuracy: 0.01)
        XCTAssertEqual(r.frame.maxX, vis.maxX - cfg.outerPadding, accuracy: 0.01)
    }

    /// Monocle is centered with wallpaper margins on both sides (not stretched across an ultrawide),
    /// and fills the full height.
    func testMonocleIsCenteredWithMargins() {
        let vis = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let cfg = LayoutConfig.default // monocleWidthFraction 0.6
        let s = StripState(ring: ring, centerId: 5, cols: 1, config: cfg)
        let c = StripLayout(s).placements(in: vis).first { $0.id == 5 }!
        let usableW = vis.width - 2 * cfg.outerPadding
        XCTAssertEqual(c.frame.width, 0.6 * usableW, accuracy: 0.01, "monocle uses its width fraction")
        XCTAssertEqual(c.frame.midX, vis.midX, accuracy: 0.5, "centered on screen")
        XCTAssertGreaterThan(c.frame.minX, vis.minX, "margin on the left")
        XCTAssertLessThan(c.frame.maxX, vis.maxX, "margin on the right")
        XCTAssertEqual(c.frame.height, vis.height - 2 * cfg.outerPadding, accuracy: 0.01, "fills height")
    }

    /// A filled monocle (fraction 1.0) spans the full usable width.
    func testFilledMonocleFillsWidth() {
        let vis = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let cfg = LayoutConfig(monocleWidthFraction: 1.0)
        let s = StripState(ring: ring, centerId: 5, cols: 1, config: cfg)
        let c = StripLayout(s).placements(in: vis).first { $0.id == 5 }!
        XCTAssertEqual(c.frame.minX, vis.minX + cfg.outerPadding, accuracy: 0.01)
        XCTAssertEqual(c.frame.maxX, vis.maxX - cfg.outerPadding, accuracy: 0.01)
    }

    /// heightFraction shrinks every window vertically and keeps them centered (margin top and bottom).
    func testHeightFractionShrinksAndCenters() {
        let vis = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let cfg = LayoutConfig(heightFraction: 0.5)
        let s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, config: cfg)
        let p = StripLayout(s).placements(in: vis)
        let usableH = vis.height - 2 * cfg.outerPadding
        for w in p where !w.parked {
            XCTAssertEqual(w.frame.height, 0.5 * usableH, accuracy: 0.01, "windows are half-height")
            XCTAssertEqual(w.frame.midY, vis.midY, accuracy: 0.5, "vertically centered")
            XCTAssertGreaterThan(w.frame.minY, vis.minY, "margin on top")
            XCTAssertLessThan(w.frame.maxY, vis.maxY, "margin on bottom")
        }
    }

    /// focusRatio is clamped to LayoutConfig.focusRatioRange so the geometry never degenerates.
    func testFocusRatioIsClamped() {
        let vis = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let cfg = LayoutConfig(focusRatio: 5.0) // absurd → clamps to the upper bound
        let s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, config: cfg)
        let c = StripLayout(s).placements(in: vis).first { $0.id == 3 }!
        let windowArea = (vis.width - 2 * cfg.outerPadding) - 2 * cfg.innerGap
        XCTAssertEqual(c.frame.width, LayoutConfig.focusRatioRange.upperBound * windowArea, accuracy: 0.01)
    }

    // MARK: - Parking

    func testFarWindowsParkOffScreen() {
        let s = StripState(ring: ring, centerId: 1, cols: 3, emphasis: .focus)
        let p = StripLayout(s).placements(in: stageVis)
        let parked = p.filter { $0.parked }
        XCTAssertFalse(parked.isEmpty, "with 7 windows and 3 slots, some must park")
        for w in parked {
            let offLeft = w.frame.maxX <= stageVis.minX
            let offRight = w.frame.minX >= stageVis.maxX
            XCTAssertTrue(offLeft || offRight, "parked window must be fully off the visible frame")
            XCTAssertNil(w.slot)
        }
    }

    func testSlottedWindowsExactlyFillSlots() {
        let s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus)
        let p = StripLayout(s).placements(in: stageVis)
        let slotted = p.filter { !$0.parked }
        XCTAssertEqual(slotted.count, 3, "3-up shows exactly 3 windows")
        XCTAssertEqual(Set(slotted.compactMap { $0.slot }), [.L, .C, .R])
    }

    // MARK: - Size constraints (learned real-window bounds feed slot sizing; see SizeConstraint)

    /// 3-up focus on 1440: window area = 1440 − 2·8 (pad) − 2·8 (gaps) = 1408; C = 704, L = R = 352.
    private func threeUp(centerId: CGWindowID = 3, emphasis: Emphasis = .focus) -> StripState {
        StripState(ring: ring, centerId: centerId, cols: 3, emphasis: emphasis,
                   config: .default)
    }
    private func slotFrames(_ p: [WindowPlacement]) -> [Slot: CGRect] {
        p.reduce(into: [:]) { acc, w in if let s = w.slot { acc[s] = w.frame } }
    }

    /// A learned floor raises its slot to the floor; the deficit comes out of the free slots
    /// proportionally, and the row still exactly fills the usable width.
    func testMinWidthRaisesSlotAndShrinksNeighborsProportionally() {
        let p = StripLayout(threeUp()).placements(in: stageVis,
                                                  constraints: [2: SizeConstraint(minWidth: 600)])
        let f = slotFrames(p)
        XCTAssertEqual(f[.L]!.width, 600, accuracy: 0.5, "slot raised to window 2's floor")
        XCTAssertEqual(f[.C]!.width / f[.R]!.width, 2.0, accuracy: 0.01,
                       "free slots keep their focus-ratio proportion (C was 2× R)")
        XCTAssertEqual(f[.L]!.minX, stageVis.minX + 8, accuracy: 0.5, "row still starts at padding")
        XCTAssertEqual(f[.R]!.maxX, stageVis.maxX - 8, accuracy: 0.5, "row still ends at padding")
    }

    /// A learned ceiling shrinks its slot to the ceiling and the neighbors absorb the surplus.
    func testMaxWidthYieldsSurplusToNeighbors() {
        let p = StripLayout(threeUp()).placements(in: stageVis,
                                                  constraints: [3: SizeConstraint(maxWidth: 400)])
        let f = slotFrames(p)
        XCTAssertEqual(f[.C]!.width, 400, accuracy: 0.5, "center capped at window 3's ceiling")
        XCTAssertEqual(f[.L]!.width, 504, accuracy: 0.5, "neighbors split the 304px surplus")
        XCTAssertEqual(f[.R]!.width, 504, accuracy: 0.5)
        XCTAssertEqual(f[.R]!.maxX, stageVis.maxX - 8, accuracy: 0.5, "row still fills the width")
    }

    /// Two constrained slots + one free: the free slot absorbs the whole difference.
    func testTwoConstrainedSlotsOneFree() {
        let p = StripLayout(threeUp()).placements(
            in: stageVis,
            constraints: [2: SizeConstraint(minWidth: 500), 4: SizeConstraint(minWidth: 500)])
        let f = slotFrames(p)
        XCTAssertEqual(f[.L]!.width, 500, accuracy: 0.5)
        XCTAssertEqual(f[.R]!.width, 500, accuracy: 0.5)
        XCTAssertEqual(f[.C]!.width, 1408 - 1000, accuracy: 0.5, "free center absorbs the deficit")
    }

    /// Floors that can't fit are emitted verbatim (commanded = achievable) and the centered row
    /// spills off both display edges — the honest last resort; nothing lies about sizes.
    func testUnsatisfiableFloorsAreEmittedVerbatimAndSpill() {
        let small = CGRect(x: 0, y: 0, width: 800, height: 600) // window area 768
        let p = StripLayout(threeUp(emphasis: .equal)).placements(
            in: small,
            constraints: [2: SizeConstraint(minWidth: 600), 4: SizeConstraint(minWidth: 600)])
        let f = slotFrames(p)
        XCTAssertEqual(f[.L]!.width, 600, accuracy: 0.5, "floor emitted, not silently shrunk")
        XCTAssertEqual(f[.R]!.width, 600, accuracy: 0.5)
        XCTAssertLessThan(f[.L]!.minX, small.minX, "row spills off the left edge")
        XCTAssertGreaterThan(f[.R]!.maxX, small.maxX, "…and the right edge")
        XCTAssertTrue(StripController.spillsOffDisplay(Array(f.values), vis: small),
                      "the controller's unsatisfiable detector fires on exactly this layout")
    }

    /// A height ceiling shrinks only that slot's height, re-centered on the strip's vertical center.
    func testHeightCeilingRecentersItsSlotOnly() {
        let p = StripLayout(threeUp()).placements(in: stageVis,
                                                  constraints: [3: SizeConstraint(maxHeight: 500)])
        let f = slotFrames(p)
        XCTAssertEqual(f[.C]!.height, 500, accuracy: 0.5)
        XCTAssertEqual(f[.C]!.midY, stageVis.midY, accuracy: 0.5, "still vertically centered")
        XCTAssertEqual(f[.L]!.height, stageVis.height - 16, accuracy: 0.5, "neighbors keep full height")
    }

    /// Monocle honors the centered window's ceiling (a fixed-size window gets a slot its own size).
    func testMonocleHonorsCeiling() {
        let s = StripState(ring: ring, centerId: 5, cols: 1, config: .default)
        let c = StripLayout(s).placements(in: stageVis,
                                          constraints: [5: SizeConstraint(maxWidth: 715, maxHeight: 652)])
            .first { $0.id == 5 }!
        XCTAssertEqual(c.frame.width, 715, accuracy: 0.5)
        XCTAssertEqual(c.frame.height, 652, accuracy: 0.5)
        XCTAssertEqual(c.frame.midX, stageVis.midX, accuracy: 0.5, "still centered")
    }

    /// A parked window's frame uses its own bounds — a fixed-size window parks at its real size,
    /// still fully off-screen.
    func testParkedWindowParksAtItsOwnSize() {
        let s = threeUp(centerId: 1) // window 5 is ring-distance −3 from center → parks off the left
        let p = StripLayout(s).placements(in: stageVis,
                                          constraints: [5: SizeConstraint(maxWidth: 300, maxHeight: 400)])
        let parked5 = p.first { $0.id == 5 }!
        XCTAssertTrue(parked5.parked)
        XCTAssertEqual(parked5.frame.width, 300, accuracy: 0.5)
        XCTAssertEqual(parked5.frame.height, 400, accuracy: 0.5)
        let offLeft = parked5.frame.maxX <= stageVis.minX
        let offRight = parked5.frame.minX >= stageVis.maxX
        XCTAssertTrue(offLeft || offRight, "still fully off-screen at its own size")
    }

    /// Constraints on parked windows must not disturb the slotted layout, and the empty default
    /// reproduces the unconstrained layout exactly (the regression pin for every existing caller).
    func testConstraintsOnParkedWindowsDontDisturbSlots() {
        let s = threeUp()
        let unconstrained = StripLayout(s).placements(in: stageVis)
        let constrained = StripLayout(s).placements(in: stageVis,
                                                    constraints: [6: SizeConstraint(minWidth: 700)])
        for (a, b) in zip(unconstrained.filter { !$0.parked }, constrained.filter { !$0.parked }) {
            XCTAssertEqual(a.frame, b.frame, "slotted frames identical — window 6 isn't slotted")
        }
    }
}

import XCTest
import CoreGraphics
@testable import StripKit

final class StripLayoutTests: XCTestCase {
    let ring: [CGWindowID] = [1, 2, 3, 4, 5, 6, 7]
    // On a 1440×900 visible frame the fraction projection is the identity, so rects equal the
    // prototype's exact stage pixels — handy for asserting geometry fidelity.
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

    // MARK: - Geometry fidelity (1440×900 ⇒ identity projection ⇒ exact prototype pixels)

    func testThreeUpFocusCenterMatchesPrototypePixels() {
        let s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus)
        let p = StripLayout(s).placements(in: stageVis)
        let center = p.first { $0.id == 3 }!
        // Prototype C box: cx=720, w=716, h=690; vertical center baseY=454.
        XCTAssertEqual(center.frame.midX, 720, accuracy: 0.01)
        XCTAssertEqual(center.frame.midY, 454, accuracy: 0.01)
        XCTAssertEqual(center.frame.width, 716, accuracy: 0.01)
        XCTAssertEqual(center.frame.height, 690, accuracy: 0.01)
        XCTAssertTrue(center.active)
        XCTAssertEqual(center.slot, .C)
    }

    func testGeometryScalesToUltrawide() {
        let vis = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus)
        let p = StripLayout(s).placements(in: vis)
        let center = p.first { $0.id == 3 }!
        // Center keeps cx=720/1440 = 0.5 of width, w=716/1440 of width.
        XCTAssertEqual(center.frame.midX, 0.5 * 3440, accuracy: 0.5)
        XCTAssertEqual(center.frame.width, 716.0 / 1440.0 * 3440.0, accuracy: 0.5)
        // Vertical: every window stays within the visible frame.
        XCTAssertGreaterThanOrEqual(center.frame.minY, vis.minY)
        XCTAssertLessThanOrEqual(center.frame.maxY, vis.maxY)
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
}

import XCTest
import CoreGraphics
@testable import StripKit

final class MotionPolicyTests: XCTestCase {
    let vis = CGRect(x: 0, y: 25, width: 3440, height: 1415)

    private func rect(midX: CGFloat, width: CGFloat = 800) -> CGRect {
        CGRect(x: midX - width / 2, y: 100, width: width, height: 1000)
    }
    private var parkedLeft: CGRect { CGRect(x: -840, y: 100, width: 800, height: 1000) }
    private var parkedRight: CGRect { CGRect(x: 3480, y: 100, width: 800, height: 1000) }

    // MARK: - Moves that must snap

    func testParkFlipFromLeftEdgeToRightEdgeSnaps() {
        XCTAssertTrue(MotionPolicy.sweepsAcross(from: parkedLeft, to: parkedRight, in: vis))
        XCTAssertTrue(MotionPolicy.sweepsAcross(from: parkedRight, to: parkedLeft, in: vis))
    }

    // MARK: - Not a sweep

    func testParkedWindowThatStaysParkedIsNotASweep() {
        // Every apply re-targets parked windows; an unchanged park must not be flagged (or logged).
        XCTAssertFalse(MotionPolicy.sweepsAcross(from: parkedLeft, to: parkedLeft, in: vis))
        let resized = CGRect(x: -1040, y: 100, width: 1000, height: 1000)
        XCTAssertFalse(MotionPolicy.sweepsAcross(from: parkedLeft, to: resized, in: vis),
                       "resized on the same edge: invisible, never crosses the display")
    }

    func testWindowOnAnotherDisplayIsNotParked() {
        // A second display to the right: a window there is on-screen, so it glides in, no snap.
        let second = CGRect(x: 3440, y: 0, width: 1920, height: 1080)
        let onSecond = CGRect(x: 3600, y: 100, width: 800, height: 600)
        let displays = [CGRect(x: 0, y: 0, width: 3440, height: 1440), second]
        XCTAssertFalse(MotionPolicy.sweepsAcross(from: onSecond, to: rect(midX: 500), in: vis,
                                                 displays: displays))
    }

    func testEmptyFrameIsNeverASweep() {
        // AX reports zero geometry for windows on other Spaces.
        XCTAssertFalse(MotionPolicy.sweepsAcross(from: .zero, to: rect(midX: 2900), in: vis))
        XCTAssertFalse(MotionPolicy.sweepsAcross(from: parkedLeft, to: .zero, in: vis))
    }

    func testLeftSeatParkingOnTheRightEdgeSnaps() {
        // 3-up with 4 windows: slide-next sends the L window to the right park — across C and R.
        XCTAssertTrue(MotionPolicy.sweepsAcross(from: rect(midX: 500), to: parkedRight, in: vis))
    }

    func testUnparkingFromTheFarEdgeSnaps() {
        // 2-up / monocle wrap: a window parked on the left lands in the right seat.
        XCTAssertTrue(MotionPolicy.sweepsAcross(from: parkedLeft, to: rect(midX: 2900), in: vis))
        XCTAssertTrue(MotionPolicy.sweepsAcross(from: parkedRight, to: rect(midX: 500), in: vis))
    }

    // MARK: - Moves that keep springing

    func testSeatToSeatSprings() {
        XCTAssertFalse(MotionPolicy.sweepsAcross(from: rect(midX: 500), to: rect(midX: 2900), in: vis))
    }

    func testParkingOnTheNearEdgeSprings() {
        // The normal film slide: L slides off the left, R slides off the right.
        XCTAssertFalse(MotionPolicy.sweepsAcross(from: rect(midX: 500), to: parkedLeft, in: vis))
        XCTAssertFalse(MotionPolicy.sweepsAcross(from: rect(midX: 2900), to: parkedRight, in: vis))
        XCTAssertFalse(MotionPolicy.sweepsAcross(from: parkedRight, to: rect(midX: 2900), in: vis))
    }

    func testCenteredWindowParksOnEitherEdge() {
        // C / monocle sits in the center band: one seat of travel either way, so it springs.
        let centered = rect(midX: vis.midX + 100, width: 2000)
        XCTAssertFalse(MotionPolicy.sweepsAcross(from: centered, to: parkedLeft, in: vis))
        XCTAssertFalse(MotionPolicy.sweepsAcross(from: centered, to: parkedRight, in: vis))
        XCTAssertFalse(MotionPolicy.sweepsAcross(from: parkedLeft, to: centered, in: vis))
    }

    // MARK: - Trades (Seats & Pile slice 1)

    func testOnlyALeftRightTradeIn3UpCuts() {
        XCTAssertTrue(MotionPolicy.tradeCuts(.L, .R, cols: 3))
        XCTAssertTrue(MotionPolicy.tradeCuts(.R, .L, cols: 3))
        XCTAssertFalse(MotionPolicy.tradeCuts(.L, .C, cols: 3), "neighbors spring")
        XCTAssertFalse(MotionPolicy.tradeCuts(.C, .R, cols: 3))
        XCTAssertFalse(MotionPolicy.tradeCuts(.L, .R, cols: 2), "in 2-up L and R are neighbors")
    }

    // MARK: - The ring produces these moves (why the rule exists)

    /// Monocle with 3 windows: the window parked on the left is parked on the RIGHT after one
    /// slide-next — the ring's wrap flips its park edge. Without the snap it springs across the screen.
    func testMonocleWrapFlipsTheParkEdge() {
        let vis = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let before = StripLayout(StripState(ring: [1, 2, 3], centerId: 1, cols: 1)).placements(in: vis)
        let after = StripLayout(StripState(ring: [1, 2, 3], centerId: 2, cols: 1)).placements(in: vis)
        let b3 = before.first { $0.id == 3 }!, a3 = after.first { $0.id == 3 }!
        XCTAssertTrue(b3.parked && b3.frame.maxX < vis.minX, "3 starts parked left")
        XCTAssertTrue(a3.parked && a3.frame.minX > vis.maxX, "3 ends parked right")
        XCTAssertTrue(MotionPolicy.sweepsAcross(from: b3.frame, to: a3.frame, in: vis))
    }

    /// 3-up with 4 windows: slide-next sends the L window to the right park.
    func testThreeUpWithFourWindowsSendsLeftSeatToRightPark() {
        let vis = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let before = StripLayout(StripState(ring: [1, 2, 3, 4], centerId: 2, cols: 3)).placements(in: vis)
        let after = StripLayout(StripState(ring: [1, 2, 3, 4], centerId: 3, cols: 3)).placements(in: vis)
        let b1 = before.first { $0.id == 1 }!, a1 = after.first { $0.id == 1 }!
        XCTAssertEqual(b1.slot, .L)
        XCTAssertTrue(a1.parked && a1.frame.minX > vis.maxX, "L window parks off the RIGHT edge")
        XCTAssertTrue(MotionPolicy.sweepsAcross(from: b1.frame, to: a1.frame, in: vis))
    }
}

import XCTest
import CoreGraphics
@testable import StripCore

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
}

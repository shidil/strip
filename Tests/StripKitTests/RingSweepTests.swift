import XCTest
import CoreGraphics
@testable import StripKit

/// Why `MotionPolicy.sweepsAcross` exists: the wrapping ring (`StripLayout`) produces moves that would
/// spring a window across the display. The rule itself is tested in StripCoreTests/MotionPolicyTests.
final class RingSweepTests: XCTestCase {

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

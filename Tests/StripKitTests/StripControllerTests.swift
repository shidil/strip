import XCTest
import CoreGraphics
@testable import StripKit

/// Pure-geometry tests for the M7 release-all escape hatch. `StripController.unparkFrame` decides
/// where a stranded/off-screen window lands when released — these assert it always returns an
/// on-screen, sensibly-sized, cascaded frame without touching AppKit/AX.
final class StripControllerTests: XCTestCase {
    // A typical ultrawide visible frame (the daily-driver target), origin offset to catch any
    // assumption that the visible frame starts at (0,0).
    let vis = CGRect(x: 0, y: 25, width: 3440, height: 1415)

    func testUnparkFrameIsComfortablySized() {
        let f = StripController.unparkFrame(index: 0, of: 1, in: vis)
        XCTAssertEqual(f.width, vis.width * 0.6, accuracy: 0.5)
        XCTAssertEqual(f.height, vis.height * 0.7, accuracy: 0.5)
    }

    func testUnparkFrameIsCenteredForLoneWindow() {
        let f = StripController.unparkFrame(index: 0, of: 1, in: vis)
        XCTAssertEqual(f.midX, vis.midX, accuracy: 0.5)
        XCTAssertEqual(f.midY, vis.midY, accuracy: 0.5)
    }

    func testUnparkFrameStaysWithinVisibleArea() {
        // Across many released windows the cascade must never push a frame off the visible area.
        for i in 0..<200 {
            let f = StripController.unparkFrame(index: i, of: 200, in: vis)
            XCTAssertGreaterThanOrEqual(f.minX, vis.minX - 0.5, "index \(i) ran off the left")
            XCTAssertGreaterThanOrEqual(f.minY, vis.minY - 0.5, "index \(i) ran off the top")
            XCTAssertLessThanOrEqual(f.maxX, vis.maxX + 0.5, "index \(i) ran off the right")
            XCTAssertLessThanOrEqual(f.maxY, vis.maxY + 0.5, "index \(i) ran off the bottom")
        }
    }

    func testUnparkFrameCascadesDistinctWindows() {
        // The first two of several released windows should not perfectly overlap.
        let a = StripController.unparkFrame(index: 0, of: 5, in: vis)
        let b = StripController.unparkFrame(index: 1, of: 5, in: vis)
        XCTAssertNotEqual(a.origin, b.origin)
    }
}

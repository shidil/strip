import XCTest
import CoreGraphics
@testable import StripKit

/// The committed-click hit test (`AccessibilityService.topWindow`): the pure half of
/// `windowID(at:)`, which reads the window server's on-screen list.
final class HitTestTests: XCTestCase {

    private func info(_ id: CGWindowID, pid: pid_t = 50, layer: Int = 0, _ r: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
         kCGWindowBounds as String: r.dictionaryRepresentation]
    }

    func testHitTestReturnsTheFrontmostNormalWindowUnderThePoint() {
        let list = [info(1, CGRect(x: 0, y: 0, width: 100, height: 100)),
                    info(2, CGRect(x: 0, y: 0, width: 500, height: 500))]
        XCTAssertEqual(AccessibilityService.topWindow(at: CGPoint(x: 50, y: 50), in: list, excludingPID: 1), 1)
        XCTAssertEqual(AccessibilityService.topWindow(at: CGPoint(x: 300, y: 50), in: list, excludingPID: 1), 2)
        XCTAssertNil(AccessibilityService.topWindow(at: CGPoint(x: 900, y: 50), in: list, excludingPID: 1))
    }

    func testHitTestSkipsStripsOwnPanelsButStopsAtTheDockOrMenuBar() {
        let point = CGPoint(x: 50, y: 50)
        let window = info(2, CGRect(x: 0, y: 0, width: 500, height: 500))
        let ring = info(9, pid: 1, layer: 3, CGRect(x: 0, y: 0, width: 500, height: 500))
        XCTAssertEqual(AccessibilityService.topWindow(at: point, in: [ring, window], excludingPID: 1), 2,
                       "Strip's focus ring sits over the window")
        let dock = info(8, pid: 77, layer: 20, CGRect(x: 0, y: 0, width: 500, height: 80))
        XCTAssertNil(AccessibilityService.topWindow(at: point, in: [dock, window], excludingPID: 1),
                     "a click on the Dock is not a click on the window behind it")
    }
}

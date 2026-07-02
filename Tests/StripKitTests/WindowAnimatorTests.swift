import XCTest
import CoreGraphics
@testable import StripKit

/// `frameMatches` is the only pure piece of the min-size-clamp detection (BUGS.md): the rest lives
/// inside `write()`'s AX-coupled background closure, not independently testable without a live
/// window. These pin the tolerance behavior that decides "matches the commanded frame" vs. "the app
/// clamped it."
final class WindowAnimatorTests: XCTestCase {
    let base = CGRect(x: 100, y: 50, width: 600, height: 400)

    func testExactMatch() {
        XCTAssertTrue(WindowAnimator.frameMatches(base, base))
    }

    func testWithinToleranceMatches() {
        let nudged = base.offsetBy(dx: 1.0, dy: -1.0)
        XCTAssertTrue(WindowAnimator.frameMatches(base, nudged, tolerance: 1.5))
    }

    func testJustOverToleranceOnOriginXFails() {
        var actual = base
        actual.origin.x += 2.0
        XCTAssertFalse(WindowAnimator.frameMatches(base, actual, tolerance: 1.5))
    }

    func testJustOverToleranceOnOriginYFails() {
        var actual = base
        actual.origin.y += 2.0
        XCTAssertFalse(WindowAnimator.frameMatches(base, actual, tolerance: 1.5))
    }

    func testJustOverToleranceOnWidthFails() {
        var actual = base
        actual.size.width += 2.0
        XCTAssertFalse(WindowAnimator.frameMatches(base, actual, tolerance: 1.5), "a clamped resize is exactly this: width differs, origin/height don't")
    }

    func testJustOverToleranceOnHeightFails() {
        var actual = base
        actual.size.height += 2.0
        XCTAssertFalse(WindowAnimator.frameMatches(base, actual, tolerance: 1.5))
    }

    func testExactlyAtToleranceMatches() {
        var actual = base
        actual.size.width += 1.5
        XCTAssertTrue(WindowAnimator.frameMatches(base, actual, tolerance: 1.5), "the boundary itself is inclusive (<=)")
    }
}

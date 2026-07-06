import XCTest
import CoreGraphics
@testable import StripKit

/// The constraint learning state machine (`SizeConstraint.learned`) is what makes closing the
/// clamp → learn → re-apply loop safe: `nil` ("nothing learned") is the controller's signal not to
/// re-apply, so these tests ARE the no-infinite-loop guarantee — every path that must not trigger
/// a re-apply (repeat clamps, sub-threshold stepping-app noise, position-only mismatches,
/// non-improving bounds) must return nil here.
final class SizeConstraintTests: XCTestCase {
    /// Screen-ish learning cap (the visible-frame size the controller passes).
    let bounds = CGSize(width: 1440, height: 900)

    // MARK: - Learning: floors (min-clamp, the Console/Activity Monitor case)

    func testGrowClampLearnsFloor() {
        // Commanded a 142px peek slot; the app came back at its 600px contentMinSize.
        let c = SizeConstraint.learned(from: nil, requested: CGSize(width: 142, height: 800),
                                       actual: CGSize(width: 600, height: 800), bounds: bounds)
        XCTAssertEqual(c?.minWidth, 600)
        XCTAssertNil(c?.minHeight, "height wasn't clamped — per-dimension learning")
        XCTAssertNil(c?.maxWidth)
        XCTAssertNil(c?.maxHeight)
    }

    func testRepeatClampTeachesNothing() {
        // The convergence contract: after learning, the same clamp must return nil (no re-apply).
        let first = SizeConstraint.learned(from: nil, requested: CGSize(width: 142, height: 800),
                                           actual: CGSize(width: 600, height: 800), bounds: bounds)
        XCTAssertNotNil(first)
        let again = SizeConstraint.learned(from: first, requested: CGSize(width: 142, height: 800),
                                           actual: CGSize(width: 600, height: 800), bounds: bounds)
        XCTAssertNil(again)
    }

    func testSubThresholdClampTeachesNothing() {
        // Terminal/stepping apps settle a few px off from cell quantization — must not churn.
        let c = SizeConstraint.learned(from: nil, requested: CGSize(width: 600, height: 800),
                                       actual: CGSize(width: 605, height: 796), bounds: bounds)
        XCTAssertNil(c)
    }

    func testPositionOnlyMismatchTeachesNothing() {
        // onFrameClamped also fires when only the origin drifted; equal sizes teach nothing.
        let s = CGSize(width: 700, height: 800)
        XCTAssertNil(SizeConstraint.learned(from: nil, requested: s, actual: s, bounds: bounds))
    }

    func testFloorIsCappedAtScreenBounds() {
        // A bad read-back can't learn an unsatisfiable floor larger than the screen.
        let c = SizeConstraint.learned(from: nil, requested: CGSize(width: 500, height: 800),
                                       actual: CGSize(width: 5000, height: 800), bounds: bounds)
        XCTAssertEqual(c?.minWidth, bounds.width)
    }

    func testFloorIsMonotonic() {
        // A later, smaller clamp never lowers a learned floor (monotone → terminating).
        let old = SizeConstraint(minWidth: 700)
        let c = SizeConstraint.learned(from: old, requested: CGSize(width: 142, height: 800),
                                       actual: CGSize(width: 600, height: 800), bounds: bounds)
        XCTAssertNil(c, "600 doesn't improve on the learned 700 floor")
    }

    func testFloorRisesWhenGenuinelyHigher() {
        let old = SizeConstraint(minWidth: 600)
        let c = SizeConstraint.learned(from: old, requested: CGSize(width: 142, height: 800),
                                       actual: CGSize(width: 740, height: 800), bounds: bounds)
        XCTAssertEqual(c?.minWidth, 740)
    }

    // MARK: - Learning: ceilings (max-clamp, the System Settings case)

    func testShrinkClampLearnsCeiling() {
        // Commanded a big slot; the effectively-fixed-size window stayed small in both dimensions.
        let c = SizeConstraint.learned(from: nil, requested: CGSize(width: 1100, height: 884),
                                       actual: CGSize(width: 715, height: 652), bounds: bounds)
        XCTAssertEqual(c?.maxWidth, 715)
        XCTAssertEqual(c?.maxHeight, 652)
        XCTAssertNil(c?.minWidth)
    }

    func testCeilingIsMonotonic() {
        let old = SizeConstraint(maxWidth: 700)
        let c = SizeConstraint.learned(from: old, requested: CGSize(width: 1100, height: 800),
                                       actual: CGSize(width: 715, height: 800), bounds: bounds)
        XCTAssertNil(c, "715 doesn't improve on the learned 700 ceiling")
    }

    func testFixedSizeEmergesAsFloorMeetsCeiling() {
        // One shrink-clamp and one grow-clamp bracket a fixed-size window: floor ≈ ceiling.
        let afterShrink = SizeConstraint.learned(from: nil, requested: CGSize(width: 1100, height: 800),
                                                 actual: CGSize(width: 715, height: 800), bounds: bounds)
        let afterGrow = SizeConstraint.learned(from: afterShrink,
                                               requested: CGSize(width: 300, height: 800),
                                               actual: CGSize(width: 715, height: 800), bounds: bounds)
        XCTAssertEqual(afterGrow?.minWidth, 715)
        XCTAssertEqual(afterGrow?.maxWidth, 715)
    }

    func testMixedClampLearnsBothDimensionsIndependently() {
        // Width clamped up (min), height clamped down (max) in the same settle.
        let c = SizeConstraint.learned(from: nil, requested: CGSize(width: 142, height: 900),
                                       actual: CGSize(width: 600, height: 652), bounds: bounds)
        XCTAssertEqual(c?.minWidth, 600)
        XCTAssertEqual(c?.maxHeight, 652)
        XCTAssertNil(c?.minHeight)
        XCTAssertNil(c?.maxWidth)
    }

    // MARK: - clamped()

    func testClampedAppliesFloorAndCeiling() {
        let c = SizeConstraint(minWidth: 600, minHeight: nil, maxWidth: nil, maxHeight: 652)
        let s = c.clamped(CGSize(width: 142, height: 900))
        XCTAssertEqual(s.width, 600)
        XCTAssertEqual(s.height, 652)
    }

    func testClampedPassesUnconstrainedDimensionsThrough() {
        let c = SizeConstraint(minWidth: 600)
        XCTAssertEqual(c.clamped(CGSize(width: 800, height: 500)), CGSize(width: 800, height: 500))
    }

    func testCrossedBoundsFloorWins() {
        // Noisy reads could cross the bounds; commanding at least the floor is always achievable.
        let c = SizeConstraint(minWidth: 700, maxWidth: 600)
        XCTAssertEqual(c.clampedWidth(650), 700)
    }
}

import XCTest
import ApplicationServices
import CoreGraphics
@testable import StripKit

/// The M7 AX-drop policy: when does a run of failed frame writes mean a window's element is dead?
/// These pin the distinction between a transient hiccup (recoverable) and a real death (drop now).
final class WriteFailureTrackerTests: XCTestCase {
    let id: CGWindowID = 42

    func testSuccessNeverDrops() {
        var t = WriteFailureTracker(threshold: 3)
        for _ in 0..<10 { XCTAssertFalse(t.record(id, error: .success)) }
    }

    func testDestroyedElementDropsImmediately() {
        var t = WriteFailureTracker(threshold: 3)
        XCTAssertTrue(t.record(id, error: .invalidUIElement), "a destroyed element is fatal at once")
    }

    func testSoftFailuresDropOnlyAtThreshold() {
        var t = WriteFailureTracker(threshold: 3)
        XCTAssertFalse(t.record(id, error: .cannotComplete))
        XCTAssertFalse(t.record(id, error: .cannotComplete))
        XCTAssertTrue(t.record(id, error: .cannotComplete), "third consecutive soft failure drops")
    }

    func testSuccessResetsTheStreak() {
        var t = WriteFailureTracker(threshold: 3)
        _ = t.record(id, error: .cannotComplete)
        _ = t.record(id, error: .cannotComplete)
        XCTAssertFalse(t.record(id, error: .success), "a good write clears the streak")
        XCTAssertFalse(t.record(id, error: .cannotComplete), "so we start counting from zero again")
        XCTAssertFalse(t.record(id, error: .cannotComplete))
        XCTAssertTrue(t.record(id, error: .cannotComplete))
    }

    func testStreaksArePerWindow() {
        var t = WriteFailureTracker(threshold: 2)
        let other: CGWindowID = 99
        XCTAssertFalse(t.record(id, error: .cannotComplete))
        // A failure on a different window must not advance this one's streak.
        XCTAssertFalse(t.record(other, error: .cannotComplete))
        XCTAssertTrue(t.record(id, error: .cannotComplete), "id's own second failure drops it")
    }

    func testForgetResetsHistory() {
        var t = WriteFailureTracker(threshold: 2)
        _ = t.record(id, error: .cannotComplete)
        t.forget(id)
        XCTAssertFalse(t.record(id, error: .cannotComplete), "after forget, streak starts over")
    }
}

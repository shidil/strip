import XCTest
import CoreGraphics
@testable import StripCore

/// Seats & Pile slice 1: the committed-click detector, focus attribution and the promote decisions.
/// All pure, with time injected.
final class PromotePolicyTests: XCTestCase {
    let interval: CFTimeInterval = 0.5 // a typical NSEvent.doubleClickInterval

    // MARK: - ClickCommitTracker

    func testAStillSingleClickCommitsAfterTheDoubleClickInterval() {
        var t = ClickCommitTracker()
        t.mouseDown(at: CGPoint(x: 100, y: 100))
        let deadline = t.mouseUp(at: CGPoint(x: 102, y: 101), clickCount: 1, now: 10, doubleClickInterval: interval)
        XCTAssertEqual(deadline, 10.5)
        XCTAssertNil(t.commit(now: 10.3), "not before the interval ends")
        XCTAssertEqual(t.commit(now: 10.5), CGPoint(x: 100, y: 100), "commits at the mouseDown point")
        XCTAssertNil(t.commit(now: 11), "only once")
    }

    func testADragOrTextSelectionNeverCommits() {
        var t = ClickCommitTracker()
        t.mouseDown(at: CGPoint(x: 100, y: 100))
        XCTAssertNil(t.mouseUp(at: CGPoint(x: 104, y: 100), clickCount: 1, now: 10, doubleClickInterval: interval),
                     "4 px of travel is a drag")
        XCTAssertNil(t.commit(now: 11))
    }

    func testADoubleClickNeverCommits() {
        var t = ClickCommitTracker()
        t.mouseDown(at: .zero)
        XCTAssertNotNil(t.mouseUp(at: .zero, clickCount: 1, now: 10, doubleClickInterval: interval))
        t.mouseDown(at: .zero) // the second click of a double-click, inside the interval
        XCTAssertFalse(t.isPending)
        XCTAssertNil(t.mouseUp(at: .zero, clickCount: 2, now: 10.2, doubleClickInterval: interval))
        XCTAssertNil(t.commit(now: 11))
    }

    func testAScrollOrCommandCancelsAPendingClick() {
        var t = ClickCommitTracker()
        t.mouseDown(at: .zero)
        _ = t.mouseUp(at: .zero, clickCount: 1, now: 10, doubleClickInterval: interval)
        t.cancel()
        XCTAssertNil(t.commit(now: 11))
    }

    func testAMouseUpWithoutAMouseDownNeverCommits() {
        var t = ClickCommitTracker()
        XCTAssertNil(t.mouseUp(at: .zero, clickCount: 1, now: 10, doubleClickInterval: interval))
    }

    func testANewClickReplacesTheOldDeadline() {
        var t = ClickCommitTracker()
        t.mouseDown(at: CGPoint(x: 1, y: 1))
        _ = t.mouseUp(at: CGPoint(x: 1, y: 1), clickCount: 1, now: 10, doubleClickInterval: interval)
        t.mouseDown(at: CGPoint(x: 500, y: 500))
        _ = t.mouseUp(at: CGPoint(x: 500, y: 500), clickCount: 1, now: 10.8, doubleClickInterval: interval)
        XCTAssertNil(t.commit(now: 10.5), "the first click's timer finds nothing to commit")
        XCTAssertEqual(t.commit(now: 11.3), CGPoint(x: 500, y: 500))
    }

    // MARK: - Attribution

    func testRecentInputAttributesTheFocusChange() {
        XCTAssertEqual(PromotePolicy.attribution(now: 10.4, lastInput: .commandKey, at: 10), .commandKey)
        XCTAssertEqual(PromotePolicy.attribution(now: 11, lastInput: .mouse, at: 10), .mouse, "edge of the window")
    }

    func testOldOrNoInputMeansAnAppCausedIt() {
        XCTAssertNil(PromotePolicy.attribution(now: 11.5, lastInput: .commandKey, at: 10))
        XCTAssertNil(PromotePolicy.attribution(now: 10, lastInput: nil, at: -.infinity))
    }

    func testOnlyCommandKeyFocusPromotesAfterTheSettle() {
        XCTAssertTrue(PromotePolicy.focusPromotes(enabled: true, attribution: .commandKey))
        XCTAssertFalse(PromotePolicy.focusPromotes(enabled: true, attribution: .mouse),
                       "a click waits for the committed-click detector")
        XCTAssertFalse(PromotePolicy.focusPromotes(enabled: true, attribution: nil), "app-caused")
        XCTAssertFalse(PromotePolicy.focusPromotes(enabled: false, attribution: .commandKey), "setting off")
    }

    // MARK: - Click promotes

    private func clickPromotes(enabled: Bool = true, focused: CGWindowID? = 7, slot: Slot? = .R,
                               locked: Bool = false, clicked: CGWindowID? = 7,
                               arrived: Bool = false) -> Bool {
        PromotePolicy.clickPromotes(enabled: enabled, focused: focused, slot: slot, primary: .C,
                                    locked: locked, clicked: clicked, focusArrivedSinceMouseDown: arrived)
    }

    func testAClickOnASatellitePromotesIt() {
        XCTAssertTrue(clickPromotes())
    }

    func testADockOrNotificationClickThatFocusedASatellitePromotesIt() {
        XCTAssertTrue(clickPromotes(clicked: nil, arrived: true))
    }

    func testAClickElsewhereWhileASatelliteHasFocusDoesNotPromote() {
        XCTAssertFalse(clickPromotes(clicked: nil, arrived: false), "menu bar / desktop click")
        XCTAssertFalse(clickPromotes(clicked: 99, arrived: false), "an unmanaged window")
    }

    func testNeverPromotesTheCenterALockedSeatAParkedWindowOrWithTheSettingOff() {
        XCTAssertFalse(clickPromotes(slot: .C))
        XCTAssertFalse(clickPromotes(locked: true))
        XCTAssertFalse(clickPromotes(slot: nil), "parked")
        XCTAssertFalse(clickPromotes(focused: nil))
        XCTAssertFalse(clickPromotes(enabled: false))
    }
}

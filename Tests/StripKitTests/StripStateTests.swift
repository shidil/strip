import XCTest
import CoreGraphics
@testable import StripKit

/// Exercises the `togglePin` state transition directly on a bare `StripState` (no AppKit/AX).
/// Engine *honoring* of pins is covered in `StripLayoutTests`; here we assert the toggle itself —
/// which slot gets pinned, where focus and center move, and that unpinning restores flow.
final class StripStateTests: XCTestCase {
    let ring: [CGWindowID] = [1, 2, 3, 4, 5, 6, 7]

    private func assignment(_ s: StripState) -> [Slot: CGWindowID] {
        StripLayout(s).assignment()
    }

    // MARK: - Pin

    func testPinFocusedSlotFixesItsWindowWhileOthersFlow() {
        // Focus L (holds window 2 when centerId=3). Pin it, then slide the film.
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, focusSlot: .L)
        XCTAssertEqual(assignment(s)[.L], 2)

        s.togglePin()
        XCTAssertEqual(s.pins[.L], 2, "L is pinned to its current window (2)")

        // Now flow the film by re-centering; the pinned window must stay in L.
        s.centerId = 5
        XCTAssertEqual(assignment(s)[.L], 2, "pinned window holds L while others flow")
        XCTAssertEqual(assignment(s)[.C], 5)
    }

    func testPinningMovesFocusOffThePinnedSlot() {
        // Focus the primary slot (C). Pinning C should hand focus to another unpinned slot.
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, focusSlot: .C)
        s.togglePin()
        XCTAssertNotNil(s.pins[.C])
        XCTAssertNotEqual(s.focusSlot, .C, "focus leaves the slot it just pinned")
        XCTAssertNil(s.pins[s.focusSlot], "focus lands on an unpinned slot")
    }

    func testPinningTheCenteredWindowMovesCenterToFirstUnpinned() {
        // centerId == window in C; pinning C must move the center to the first unpinned ring window.
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, focusSlot: .C)
        XCTAssertEqual(assignment(s)[.C], 3)

        s.togglePin()
        XCTAssertEqual(s.pins[.C], 3, "the centered window (3) got pinned")
        let pinned = Set(s.pins.values)
        XCTAssertFalse(pinned.contains(s.centerId!), "center is no longer a pinned window")
        XCTAssertEqual(s.centerId, ring.first { !pinned.contains($0) },
                       "center moved to the first unpinned ring window")
    }

    // MARK: - Unpin

    func testUnpinRestoresFlow() {
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, focusSlot: .L)
        s.togglePin()
        XCTAssertNotNil(s.pins[.L])

        // Toggling the same slot again unpins it.
        s.focusSlot = .L
        s.togglePin()
        XCTAssertNil(s.pins[.L], "second toggle on the same slot unpins")
        XCTAssertTrue(s.pins.isEmpty)
    }

    // MARK: - setCenter (rail-chip click)

    func testSetCenterCentersAndResetsFocusToPrimary() {
        var s = StripState(ring: ring, centerId: 1, cols: 3, emphasis: .focus, focusSlot: .R)
        s.setCenter(5)
        XCTAssertEqual(s.centerId, 5)
        XCTAssertEqual(s.focusSlot, s.primarySlot, "focus returns to the anchor slot")
        XCTAssertEqual(assignment(s)[.C], 5)
    }

    func testSetCenterUnpinsAPinnedTarget() {
        // Pin window 7 in L, then center it: it should unpin and flow to the anchor.
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, pins: [.L: 7])
        s.setCenter(7)
        XCTAssertFalse(s.pins.values.contains(7), "centering a pinned window unpins it")
        XCTAssertEqual(s.centerId, 7)
        XCTAssertEqual(assignment(s)[.C], 7)
    }

    func testSetCenterIgnoresUnknownWindow() {
        var s = StripState(ring: ring, centerId: 3, cols: 3)
        s.setCenter(999)
        XCTAssertEqual(s.centerId, 3, "unknown id is a no-op")
    }

    // MARK: - Edge cases

    func testPinningAnEmptySlotIsANoOp() {
        // With an empty ring the focused slot holds no window, so there is nothing to pin.
        var s = StripState(ring: [], centerId: nil, cols: 3, focusSlot: .C)
        s.togglePin()
        XCTAssertTrue(s.pins.isEmpty, "nothing to pin when the focused slot is empty")
    }
}

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

    func testPinningKeepsFocusOnThePinnedSlot() {
        // Focus the primary slot (C). Pinning C must leave focus on C — a pinned window stays
        // focusable, so its focus ring holds rather than jumping to a neighbor.
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, focusSlot: .C)
        s.togglePin()
        XCTAssertNotNil(s.pins[.C])
        XCTAssertEqual(s.focusSlot, .C, "focus stays on the slot it just pinned")
        XCTAssertEqual(StripLayout(s).activeId, s.pins[.C],
                       "the pinned window is the active/focused window (ring has a window to track)")
    }

    func testFocusNavigationLandsOnAndPassesThePinnedSlot() {
        // Pin C, then move focus from L: K must land on the pinned C slot (not skip it), and a
        // second K must pass it to R.
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, focusSlot: .C)
        s.togglePin()                                 // pin the window in C, focus stays C
        s.focusSlot = .L
        s.focusSlot = s.focusSlotAfterMove(1)
        XCTAssertEqual(s.focusSlot, .C, "K moves focus onto the pinned center slot")
        s.focusSlot = s.focusSlotAfterMove(1)
        XCTAssertEqual(s.focusSlot, .R, "another K moves focus past the pinned slot to R")
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

    // MARK: - insertManaged (new-window placement, M6)

    func testNewWindowCentersAndTakesFocus() {
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, focusSlot: .R)
        s.insertManaged(99, placement: .focusCenter)
        XCTAssertEqual(s.centerId, 99, "new window becomes the centered window")
        XCTAssertEqual(assignment(s)[.C], 99, "and lands in the center slot")
        XCTAssertEqual(s.focusSlot, .C, "focus moves to it")
        XCTAssertTrue(s.ring.contains(99))
    }

    func testNewWindowOpensRightOfFocusInTheFilm() {
        // The new window should be inserted into the ring *right after* the currently-focused window
        // and centered, so the previous focus flows into the slot immediately to its left and the
        // film stays contiguous (rather than the new window landing at the far end).
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, focusSlot: .R)
        let oldFocus = assignment(s)[.R]!            // the window currently focused (in R)
        s.insertManaged(99, placement: .focusCenter)

        XCTAssertEqual(assignment(s)[.C], 99, "new window centers")
        XCTAssertEqual(s.focusSlot, .C, "and takes focus")
        XCTAssertEqual(assignment(s)[.L], oldFocus, "previous focus flows to the slot left of it")
        let fi = s.ring.firstIndex(of: oldFocus)!
        XCTAssertEqual(s.ring[fi + 1], 99, "new window sits right after the focused window in the film")
    }

    func testNewWindowLandsRightWhenCenterIsPinned() {
        // Pin C; the next preference (right) should receive the new window, leaving the pin intact.
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, pins: [.C: 4])
        s.insertManaged(99, placement: .focusCenter)
        XCTAssertEqual(s.pins[.C], 4, "the pinned center window is untouched")
        XCTAssertEqual(assignment(s)[.C], 4)
        XCTAssertEqual(assignment(s)[.R], 99, "new window takes the right slot")
        XCTAssertEqual(s.focusSlot, .R)
    }

    func testNewWindowLandsLeftWhenCenterAndRightPinned() {
        // C and R pinned → only L is free, so the new window goes there.
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, pins: [.C: 4, .R: 5])
        s.insertManaged(99, placement: .focusCenter)
        XCTAssertEqual(assignment(s)[.L], 99, "new window takes the only free slot, left")
        XCTAssertEqual(s.focusSlot, .L)
        XCTAssertEqual(s.pins[.C], 4)
        XCTAssertEqual(s.pins[.R], 5)
    }

    func testNewWindowIntoEmptyStripBecomesCenter() {
        var s = StripState(ring: [], centerId: nil, cols: 3, emphasis: .focus)
        s.insertManaged(99, placement: .focusCenter)
        XCTAssertEqual(s.centerId, 99)
        XCTAssertEqual(assignment(s)[.C], 99)
    }

    func testAppendPlacementDoesNotStealFocusOrCenter() {
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, focusSlot: .R)
        s.insertManaged(99, placement: .append)
        XCTAssertEqual(s.ring.last, 99, "appended at the end of the film")
        XCTAssertEqual(s.centerId, 3, "center unchanged")
        XCTAssertEqual(s.focusSlot, .R, "focus unchanged")
    }

    func testInsertIsIdempotentForAKnownWindow() {
        var s = StripState(ring: ring, centerId: 3, cols: 3)
        let before = s
        s.insertManaged(4, placement: .focusCenter) // 4 already in the ring
        XCTAssertEqual(s.ring, before.ring, "re-inserting an existing window is a no-op")
        XCTAssertEqual(s.centerId, before.centerId)
    }

    // MARK: - Closing the centered window (successor pick, M6)

    func testClosingCenteredWindowFallsToLeftNeighbor() {
        // L=2, C=3 (centered), R=4. Close 3 → center should become 2 (the left neighbor), not the
        // start of the film (1).
        let old = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, focusSlot: .C)
        XCTAssertEqual(assignment(old)[.L], 2)
        let survivors: Set<CGWindowID> = [1, 2, 4, 5, 6, 7] // 3 closed
        XCTAssertEqual(StripController.neighborOfClosedCenter(in: old, survivors: survivors), 2)
    }

    func testClosingCenteredWindowFallsToRightWhenLeftAlsoGone() {
        let old = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, focusSlot: .C)
        let survivors: Set<CGWindowID> = [1, 4, 5, 6, 7] // both 2 (left) and 3 (center) closed
        XCTAssertEqual(StripController.neighborOfClosedCenter(in: old, survivors: survivors), 4,
                       "falls to the right neighbor when the left one is also gone")
    }

    func testClosingCenteredWindowReturnsNilWhenNoFlankSurvives() {
        // Only the centered window had neighbors and they're all gone (monocle has no flanks).
        let old = StripState(ring: [3], centerId: 3, cols: 1)
        XCTAssertNil(StripController.neighborOfClosedCenter(in: old, survivors: []))
    }

    // MARK: - Edge cases

    func testPinningAnEmptySlotIsANoOp() {
        // With an empty ring the focused slot holds no window, so there is nothing to pin.
        var s = StripState(ring: [], centerId: nil, cols: 3, focusSlot: .C)
        s.togglePin()
        XCTAssertTrue(s.pins.isEmpty, "nothing to pin when the focused slot is empty")
    }
}

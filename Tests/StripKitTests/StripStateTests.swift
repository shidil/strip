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

    // MARK: - replaceWindow (native tab switch)

    func testReplaceWindowTakesOverRingPositionAndCenter() {
        var s = StripState(ring: ring, centerId: 3, cols: 3)
        let before = assignment(s)
        s.replaceWindow(3, with: 99)
        XCTAssertEqual(s.ring, ring.map { $0 == 3 ? 99 : $0 })
        XCTAssertEqual(s.centerId, 99)
        XCTAssertEqual(assignment(s)[.C], 99, "the new window shows where the old one did")
        XCTAssertEqual(assignment(s)[.L], before[.L])
        XCTAssertEqual(assignment(s)[.R], before[.R])
    }

    func testReplaceWindowKeepsAPin() {
        var s = StripState(ring: ring, centerId: 3, cols: 3, emphasis: .focus, pins: [.L: 7])
        s.replaceWindow(7, with: 99)
        XCTAssertEqual(s.pins[.L], 99)
        XCTAssertEqual(s.centerId, 3, "replacing a non-center window leaves the center alone")
    }

    func testReplaceWindowIgnoresUnknownOrAlreadyManaged() {
        var s = StripState(ring: ring, centerId: 3, cols: 3)
        s.replaceWindow(999, with: 98)
        XCTAssertEqual(s.ring, ring, "unknown old id is a no-op")
        s.replaceWindow(3, with: 5)
        XCTAssertEqual(s.ring, ring, "a new id already in the ring would duplicate it — no-op")
        XCTAssertEqual(s.centerId, 3)
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

    // MARK: - Seat keys (Seats & Pile slice 1)

    func testSeatKeysNameLeftCenterRightPerColumnCount() {
        let three = StripState(ring: ring, cols: 3)
        XCTAssertEqual(SeatKey.allCases.map(three.seat(for:)), [.L, .C, .R])
        let two = StripState(ring: ring, cols: 2)
        XCTAssertEqual(SeatKey.allCases.map(two.seat(for:)), [.L, .L, .R], "2-up: L acts as the center")
        let mono = StripState(ring: ring, cols: 1)
        XCTAssertEqual(SeatKey.allCases.map(mono.seat(for:)), [.C, .C, .C], "monocle: every key means C")
    }

    // MARK: - Pile order

    /// 3-up, ring 1…7 centered on 3: L=2 C=3 R=4; 5, 6, 7, 1 parked.
    private var threeUp: StripState { StripState(ring: ring, centerId: 3, cols: 3, focusSlot: .C) }

    func testPileSeedsFromTheRingNearestTheCenterFirst() {
        XCTAssertEqual(threeUp.pile, [5, 1, 6, 7], "distance 2 (right, then left), then distance 3")
    }

    func testPileFollowsRecencyBeforeRingDistance() {
        var s = threeUp
        s.mru = [6, 3, 7]
        XCTAssertEqual(s.pile, [6, 7, 5, 1], "seated 3 is skipped; unknown windows follow by distance")
    }

    func testPruneDropsWindowsThatLeftTheRing() {
        var s = threeUp
        s.mru = [6, 99, 3]
        s.lastTrade = Trade(a: 99, b: 3, from: .R, to: .C)
        s.pruneMRU()
        XCTAssertEqual(s.mru, [6, 3])
        XCTAssertNil(s.lastTrade)
    }

    // MARK: - Draw

    /// Frames of every window except `ids`, so a test can assert nothing else moved.
    private func frames(_ s: StripState, except ids: Set<CGWindowID>) -> [CGWindowID: CGRect] {
        let vis = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        var out: [CGWindowID: CGRect] = [:]
        for p in StripLayout(s).placements(in: vis) where !ids.contains(p.id) { out[p.id] = p.frame }
        return out
    }

    /// Every managed window is either in a seat or in the pile, never both (design invariant).
    private func assertSeatsAndPilePartitionTheRing(_ s: StripState, file: StaticString = #filePath, line: UInt = #line) {
        let seated = Set(assignment(s).values)
        XCTAssertTrue(seated.isDisjoint(with: s.pile), "a window is both seated and in the pile", file: file, line: line)
        XCTAssertEqual(seated.union(s.pile), Set(s.ring), "a window is lost", file: file, line: line)
        XCTAssertEqual(s.pile.count, Set(s.pile).count, "the pile repeats a window", file: file, line: line)
    }

    func testDrawIntoASatelliteSwapsTwoWindowsAndTogglesBack() {
        var s = threeUp
        let before = frames(s, except: [4, 5])
        XCTAssertEqual(s.draw(into: .R), Draw(drawn: 5, displaced: 4, seat: .R))
        XCTAssertEqual(assignment(s), [.L: 2, .C: 3, .R: 5])
        XCTAssertEqual(s.focusSlot, .C, "focus stays where it was")
        XCTAssertEqual(s.pile.first, 4, "the displaced window tops the pile")
        XCTAssertEqual(frames(s, except: [4, 5]), before, "nothing else moves")
        assertSeatsAndPilePartitionTheRing(s)

        XCTAssertEqual(s.draw(into: .R), Draw(drawn: 4, displaced: 5, seat: .R), "drawing again toggles back")
        XCTAssertEqual(assignment(s), [.L: 2, .C: 3, .R: 4])
        XCTAssertEqual(s.pile.first, 5)
    }

    func testTheDisplacedWindowTopsADeeperPile() {
        // With a real recency history the displaced window must still be the next draw, ahead of
        // more recently used parked windows — otherwise a second ⌃⌥O wouldn't toggle back.
        var s = threeUp
        s.mru = [3, 6, 7, 2, 4]
        XCTAssertEqual(s.draw(into: .R)?.drawn, 6, "pile[0] is the most recent parked window")
        XCTAssertEqual(s.pile, [4, 7, 5, 1])
        XCTAssertEqual(s.draw(into: .R)?.drawn, 4, "drawing again toggles back")
        XCTAssertEqual(s.pile.first, 6)
    }

    func testDrawIntoTheCenterFocusesItAndTogglesBetweenTheTwoMostRecent() {
        var s = threeUp
        s.focusSlot = .L
        XCTAssertEqual(s.draw(into: .C), Draw(drawn: 5, displaced: 3, seat: .C))
        XCTAssertEqual(assignment(s), [.L: 2, .C: 5, .R: 4])
        XCTAssertEqual(s.centerId, 5)
        XCTAssertEqual(s.focusSlot, .C, "a draw into the center focuses it")
        XCTAssertEqual(Array(s.mru.prefix(2)), [5, 3])
        assertSeatsAndPilePartitionTheRing(s)

        XCTAssertEqual(s.draw(into: .C)?.drawn, 3, "⌃⌥I again flips back to the previous center")
        XCTAssertEqual(s.draw(into: .C)?.drawn, 5)
    }

    func testDrawInMonocleTogglesTheCenter() {
        var s = StripState(ring: [1, 2, 3], centerId: 1, cols: 1)
        s.mru = [1, 3, 2]
        XCTAssertEqual(s.draw(into: s.seat(for: .u))?.drawn, 3, "pile[0] is the most recent parked window")
        XCTAssertEqual(assignment(s), [.C: 3])
        XCTAssertEqual(s.draw(into: .C)?.drawn, 1)
        assertSeatsAndPilePartitionTheRing(s)
    }

    func testExplicitDrawWorksOnALockedSeatAndKeepsTheLock() {
        var s = threeUp
        s.pins = [.R: 4]
        let before = frames(s, except: [4, 5])
        XCTAssertEqual(s.draw(into: .R)?.drawn, 5)
        XCTAssertEqual(s.pins[.R], 5, "the lock now holds the drawn window")
        XCTAssertEqual(assignment(s), [.L: 2, .C: 3, .R: 5])
        XCTAssertEqual(s.pile.first, 4)
        XCTAssertEqual(frames(s, except: [4, 5]), before, "nothing else moves")
        assertSeatsAndPilePartitionTheRing(s)
    }

    func testDrawWithAnEmptyPileIsANoOp() {
        var s = StripState(ring: [1, 2, 3], centerId: 2, cols: 3)
        XCTAssertNil(s.draw(into: .R))
        XCTAssertEqual(s.ring, [1, 2, 3])
    }

    // MARK: - Trade (⌃⌥⇧U / I / O)

    func testTradeCenterWithRightAndFocusGoesWithTheWindow() {
        var s = threeUp
        XCTAssertEqual(s.trade(with: .R), Trade(a: 3, b: 4, from: .C, to: .R))
        XCTAssertEqual(assignment(s), [.L: 2, .C: 4, .R: 3])
        XCTAssertEqual(s.focusSlot, .R)
        XCTAssertEqual(s.lastTrade, Trade(a: 3, b: 4, from: .C, to: .R))
    }

    func testTradeLeftWithRightLeavesTheCenterAndPileAlone() {
        var s = threeUp
        s.focusSlot = .L
        let before = frames(s, except: [2, 4])
        XCTAssertEqual(s.trade(with: .R), Trade(a: 2, b: 4, from: .L, to: .R))
        XCTAssertEqual(assignment(s), [.L: 4, .C: 3, .R: 2])
        XCTAssertEqual(s.centerId, 3)
        XCTAssertEqual(frames(s, except: [2, 4]), before, "nothing else moves")
    }

    func testTradeIsItsOwnInverse() {
        var s = threeUp
        let original = s.ring
        s.trade(with: .R)
        s.trade(with: .C)
        XCTAssertEqual(s.ring, original)
        XCTAssertEqual(s.centerId, 3)
        XCTAssertEqual(s.focusSlot, .C)
    }

    func testTradeInTwoUp() {
        var s = StripState(ring: [1, 2, 3], centerId: 1, cols: 2, focusSlot: .R)
        XCTAssertEqual(s.trade(with: s.seat(for: .i)), Trade(a: 2, b: 1, from: .R, to: .L))
        XCTAssertEqual(assignment(s), [.L: 2, .R: 1])
        XCTAssertEqual(s.centerId, 2)
    }

    func testTradeIsANoOpOnALockedSeatInMonocleOrOntoItself() {
        var s = threeUp
        s.pins = [.R: 4]
        XCTAssertNil(s.trade(with: .R), "locked target")
        s.focusSlot = .R
        XCTAssertNil(s.trade(with: .L), "locked source")
        s.pins = [:]
        XCTAssertNil(s.trade(with: .R), "onto itself")
        var mono = StripState(ring: ring, centerId: 3, cols: 1)
        XCTAssertNil(mono.trade(with: .C))
        XCTAssertEqual(s.ring, ring)
    }

    // MARK: - Promote (⌃⌥↩, click, ⌘Tab)

    func testPromoteTradesTheFocusedSatelliteIntoTheCenterAndUndoesOnTheCenter() {
        var s = threeUp
        s.focusSlot = .R
        XCTAssertEqual(s.promote(), Trade(a: 4, b: 3, from: .R, to: .C))
        XCTAssertEqual(assignment(s), [.L: 2, .C: 4, .R: 3])
        XCTAssertEqual(s.focusSlot, .C, "focus goes with the promoted window")

        XCTAssertEqual(s.promote()?.from, .C, "promote on the center undoes the last trade")
        XCTAssertEqual(assignment(s), [.L: 2, .C: 3, .R: 4])
        XCTAssertEqual(s.focusSlot, .C, "focus stays on the center")

        s.promote()
        XCTAssertEqual(assignment(s)[.C], 4, "and again redoes it")
    }

    func testPromoteOnTheCenterWithNoTradeIsANoOp() {
        var s = threeUp
        XCTAssertNil(s.promote())
        XCTAssertEqual(s.ring, ring)
    }

    func testPromoteByIdMovesAVisibleSatelliteIntoTheCenter() {
        var s = threeUp
        XCTAssertEqual(s.promote(2), Trade(a: 2, b: 3, from: .L, to: .C))
        XCTAssertEqual(assignment(s), [.L: 3, .C: 2, .R: 4])
        XCTAssertEqual(s.focusSlot, .C)
    }

    func testPromoteByIdNeverMovesALockedParkedOrCenterWindow() {
        var s = threeUp
        s.pins = [.L: 2]
        XCTAssertNil(s.promote(2), "locked seat")
        XCTAssertNil(s.promote(3), "already the center")
        XCTAssertNil(s.promote(6), "parked")
        XCTAssertEqual(s.focusSlot, .C)
        var mono = StripState(ring: ring, centerId: 3, cols: 1)
        XCTAssertNil(mono.promote(4), "monocle")
        XCTAssertEqual(s.ring, ring)
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

    // MARK: - focusFollow (Seats & Pile slice 0)

    func testFocusFollowMovesFocusToTheClickedSlotWithoutMovingTheFilm() {
        var s = StripState(ring: [1, 2, 3, 4, 5], centerId: 3, cols: 3, focusSlot: .C)
        let before = StripLayout(s).assignment()
        XCTAssertEqual(s.focusFollow(4), .R)
        XCTAssertEqual(s.focusSlot, .R)
        XCTAssertEqual(s.centerId, 3, "center unchanged")
        XCTAssertEqual(StripLayout(s).assignment(), before, "no window changes slot")
        XCTAssertEqual(s.focusSlotAfterMove(-1), .C, "J now steps from R, not from the stale C")
    }

    func testFocusFollowIgnoresParkedWindows() {
        var s = StripState(ring: [1, 2, 3, 4, 5], centerId: 3, cols: 3, focusSlot: .C)
        XCTAssertNil(s.focusFollow(5), "5 is parked")
        XCTAssertEqual(s.focusSlot, .C)
    }

    func testFocusFollowReachesAPinnedSlot() {
        var s = StripState(ring: [1, 2, 3, 4, 5], centerId: 3, cols: 3,
                           pins: [.L: 1], focusSlot: .C)
        XCTAssertEqual(s.focusFollow(1), .L)
    }

    // MARK: - summon (Seats & Pile slice 0)

    func testSummonSwapsAParkedWindowIntoTheCenterAndMovesNothingElse() {
        // 3-up, ring 1…6 centered on 3: L=2 C=3 R=4; 1, 5, 6 parked.
        var s = StripState(ring: [1, 2, 3, 4, 5, 6], centerId: 3, cols: 3, focusSlot: .R)
        XCTAssertEqual(s.summon(6), 3, "returns the displaced center")
        let a = StripLayout(s).assignment()
        XCTAssertEqual(a[.C], 6)
        XCTAssertEqual(a[.L], 2, "L unchanged")
        XCTAssertEqual(a[.R], 4, "R unchanged")
        XCTAssertEqual(s.focusSlot, .C)
        XCTAssertFalse(a.values.contains(3), "old center is parked")
        XCTAssertEqual(Set(s.ring), [1, 2, 3, 4, 5, 6], "membership unchanged")
        XCTAssertEqual(s.mru, [6, 3], "the summoned window is most recent; the old center tops the pile")
        XCTAssertEqual(s.pile.first, 3)
    }

    func testSummonInTwoUpLandsInTheLeftAnchor() {
        var s = StripState(ring: [1, 2, 3], centerId: 1, cols: 2, focusSlot: .R)
        // 2-up: L=1 (anchor) R=2; 3 parked.
        XCTAssertEqual(s.summon(3), 1)
        let a = StripLayout(s).assignment()
        XCTAssertEqual(a[.L], 3)
        XCTAssertEqual(a[.R], 2)
        XCTAssertEqual(s.focusSlot, .L)
    }

    func testSummonIsANoOpForVisiblePinnedOrUnknownWindows() {
        var s = StripState(ring: [1, 2, 3, 4, 5], centerId: 3, cols: 3, pins: [.L: 2])
        let before = s.ring
        XCTAssertNil(s.summon(4), "already visible")
        XCTAssertNil(s.summon(2), "pinned")
        XCTAssertNil(s.summon(99), "not in the ring")
        XCTAssertEqual(s.ring, before)
    }
}

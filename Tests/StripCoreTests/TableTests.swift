import XCTest
import CoreGraphics
@testable import StripCore

/// The Table's verbs (Seats & Pile step 2). The draw / trade / promote / focus / summon cases are
/// ported from `StripStateTests` (step 1, on the ring); pick, pass and columns are new.
final class TableTests: XCTestCase {
    /// 3-up: L=2 C=3 R=4; pile 5, 1, 6, 7 — what the ring 1…7 centered on 3 seeds.
    private var threeUp: Table { Table(seats: [.L: 2, .C: 3, .R: 4], pile: [5, 1, 6, 7]) }

    private func assertSound(_ t: Table, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(t.invariantViolations(), [], file: file, line: line)
    }

    // MARK: - Seats

    func testSeatKeysNameLeftCenterRightPerColumnCount() {
        XCTAssertEqual(SeatKey.allCases.map(Table(cols: 3).seat(for:)), [.L, .C, .R])
        XCTAssertEqual(SeatKey.allCases.map(Table(cols: 2).seat(for:)), [.L, .L, .R], "2-up: L acts as the center")
        XCTAssertEqual(SeatKey.allCases.map(Table(cols: 1).seat(for:)), [.C, .C, .C], "monocle: every key means C")
        XCTAssertEqual(Table(cols: 2).primary, .L)
        XCTAssertEqual(Table(cols: 2).focusSeat, .L, "focus starts on the primary seat")
    }

    func testLandingSeatIsTheCenterThenRightThenLeftAndOverridesWhenEverySeatIsLocked() {
        var t = threeUp
        XCTAssertEqual(t.landingSeat, .C)
        t.locks = [.C]
        XCTAssertEqual(t.landingSeat, .R)
        t.locks = [.C, .R]
        XCTAssertEqual(t.landingSeat, .L)
        t.locks = [.L, .C, .R]
        XCTAssertEqual(t.landingSeat, .C, "every seat locked: a summon you caused still lands in C")
    }

    // MARK: - Draw

    func testDrawIntoASatelliteSwapsTwoWindowsAndTogglesBack() {
        var t = threeUp
        XCTAssertTrue(t.draw(into: .R))
        XCTAssertEqual(t.seats, [.L: 2, .C: 3, .R: 5])
        XCTAssertEqual(t.focusSeat, .C, "focus stays where it was")
        XCTAssertEqual(t.pile, [4, 1, 6, 7], "the displaced window tops the pile")
        assertSound(t)

        XCTAssertTrue(t.draw(into: .R), "drawing again toggles back")
        XCTAssertEqual(t, threeUp)
    }

    func testTheDisplacedWindowTopsADeeperPile() {
        var t = threeUp
        t.pile = [6, 7, 5, 1]
        t.draw(into: .R)
        XCTAssertEqual(t.seats[.R], 6, "pile[0] is the most recent parked window")
        XCTAssertEqual(t.pile, [4, 7, 5, 1])
        t.draw(into: .R)
        XCTAssertEqual(t.seats[.R], 4, "drawing again toggles back")
        XCTAssertEqual(t.pile.first, 6)
    }

    func testDrawIntoTheCenterFocusesItAndTogglesBetweenTheTwoMostRecent() {
        var t = threeUp
        t.focusSeat = .L
        t.draw(into: .C)
        XCTAssertEqual(t.seats, [.L: 2, .C: 5, .R: 4])
        XCTAssertEqual(t.focusSeat, .C, "a draw into the center focuses it")
        XCTAssertEqual(t.pile.first, 3)
        t.draw(into: .C)
        XCTAssertEqual(t.seats[.C], 3, "⌃⌥I again flips back to the previous center")
        t.draw(into: .C)
        XCTAssertEqual(t.seats[.C], 5)
        assertSound(t)
    }

    func testDrawInMonocleTogglesTheCenter() {
        var t = Table(seats: [.C: 1], pile: [3, 2], cols: 1)
        t.draw(into: t.seat(for: .u))
        XCTAssertEqual(t.seats, [.C: 3])
        t.draw(into: .C)
        XCTAssertEqual(t.seats, [.C: 1])
        XCTAssertEqual(t.pile, [3, 2])
    }

    func testExplicitDrawWorksOnALockedSeatAndKeepsTheLock() {
        var t = threeUp
        t.locks = [.R]
        XCTAssertTrue(t.draw(into: .R))
        XCTAssertEqual(t.seats[.R], 5)
        XCTAssertEqual(t.locks, [.R], "the lock now holds the drawn window")
        XCTAssertEqual(t.pile.first, 4)
    }

    func testDrawWithAnEmptyPileIsANoOp() {
        var t = Table(seats: [.L: 1, .C: 2, .R: 3])
        XCTAssertFalse(t.draw(into: .R))
        XCTAssertEqual(t, Table(seats: [.L: 1, .C: 2, .R: 3]))
    }

    func testDrawFillsAnEmptySatellite() {
        var t = Table(seats: [.C: 3, .R: 4], pile: [5, 6])
        XCTAssertTrue(t.draw(into: .L))
        XCTAssertEqual(t.seats, [.L: 5, .C: 3, .R: 4])
        XCTAssertEqual(t.pile, [6], "nothing was displaced")
    }

    func testDrawIntoASeatWithAHoleKeepsTheHole() {
        var t = Table(seats: [.C: 3, .R: 4], pile: [5], holes: [.L: 2])
        t.draw(into: .L)
        XCTAssertEqual(t.seats[.L], 5)
        XCTAssertEqual(t.holes, [.L: 2], "the restore decides who keeps the seat")
        assertSound(t)
    }

    // MARK: - Trade (⌃⌥⇧U / I / O)

    func testTradeCenterWithRightAndFocusGoesWithTheWindow() {
        var t = threeUp
        XCTAssertTrue(t.trade(with: .R))
        XCTAssertEqual(t.seats, [.L: 2, .C: 4, .R: 3])
        XCTAssertEqual(t.focusSeat, .R)
        XCTAssertEqual(t.lastTrade, Trade(a: 3, b: 4, from: .C, to: .R))
    }

    func testTradeLeftWithRightLeavesTheCenterAndPileAlone() {
        var t = threeUp
        t.focusSeat = .L
        t.trade(with: .R)
        XCTAssertEqual(t.seats, [.L: 4, .C: 3, .R: 2])
        XCTAssertEqual(t.pile, threeUp.pile)
    }

    func testTradeInTwoUp() {
        var t = Table(seats: [.L: 1, .R: 2], pile: [3], focusSeat: .R, cols: 2)
        XCTAssertTrue(t.trade(with: t.seat(for: .i)))
        XCTAssertEqual(t.seats, [.L: 2, .R: 1])
        XCTAssertEqual(t.focusSeat, .L)
    }

    func testTradeIsANoOpOnALockedSeatInMonocleOntoItselfOrAnEmptySeat() {
        var t = threeUp
        t.locks = [.R]
        XCTAssertFalse(t.trade(with: .R), "locked target")
        t.focusSeat = .R
        XCTAssertFalse(t.trade(with: .L), "locked source")
        t.locks = []
        XCTAssertFalse(t.trade(with: .R), "onto itself")
        var mono = Table(seats: [.C: 3], pile: [1], cols: 1)
        XCTAssertFalse(mono.trade(with: .C))
        var gap = Table(seats: [.C: 3, .R: 4])
        XCTAssertFalse(gap.trade(with: .L), "empty seat")
        XCTAssertEqual(t.seats, threeUp.seats)
    }

    // MARK: - Promote (⌃⌥↩, click, ⌘Tab)

    func testPromoteTradesTheFocusedSatelliteIntoTheCenterAndUndoesOnTheCenter() {
        var t = threeUp
        t.focusSeat = .R
        XCTAssertTrue(t.promote())
        XCTAssertEqual(t.seats, [.L: 2, .C: 4, .R: 3])
        XCTAssertEqual(t.focusSeat, .C, "focus goes with the promoted window")
        XCTAssertEqual(t.lastTrade, Trade(a: 4, b: 3, from: .R, to: .C))

        XCTAssertTrue(t.promote(), "promote on the center undoes the last trade")
        XCTAssertEqual(t.seats, threeUp.seats)
        XCTAssertEqual(t.focusSeat, .C, "focus stays on the center")

        t.promote()
        XCTAssertEqual(t.seats[.C], 4, "and again redoes it")
    }

    func testPromoteOnTheCenterWithNoTradeIsANoOp() {
        var t = threeUp
        XCTAssertFalse(t.promote())
        XCTAssertEqual(t, threeUp)
    }

    func testPromoteByIdMovesAVisibleSatelliteIntoTheCenter() {
        var t = threeUp
        XCTAssertTrue(t.promote(2))
        XCTAssertEqual(t.seats, [.L: 3, .C: 2, .R: 4])
        XCTAssertEqual(t.focusSeat, .C)
        XCTAssertEqual(t.lastTrade, Trade(a: 2, b: 3, from: .L, to: .C))
    }

    func testPromoteByIdNeverMovesALockedParkedOrCenterWindow() {
        var t = threeUp
        t.locks = [.L]
        t.focusSeat = .R
        XCTAssertFalse(t.promote(2), "locked seat")
        XCTAssertFalse(t.promote(3), "already the center")
        XCTAssertFalse(t.promote(6), "parked")
        XCTAssertEqual(t.focusSeat, .R, "focus untouched by a refused promote")
        var mono = Table(seats: [.C: 3], pile: [4], cols: 1)
        XCTAssertFalse(mono.promote(4), "monocle")
        XCTAssertEqual(t.seats, threeUp.seats)
    }

    // MARK: - Pick (Overview, search, rail) and summon

    func testPickFromThePileIsADrawIntoTheNamedSeat() {
        var t = threeUp
        t.focusSeat = .L
        XCTAssertTrue(t.pick(6, into: .R))
        XCTAssertEqual(t.seats, [.L: 2, .C: 3, .R: 6])
        XCTAssertEqual(t.pile, [4, 5, 1, 7], "the displaced window tops the pile")
        XCTAssertEqual(t.focusSeat, .L, "a pick into a satellite leaves focus where it was")

        XCTAssertTrue(t.pick(7, into: .C))
        XCTAssertEqual(t.seats[.C], 7)
        XCTAssertEqual(t.pile.first, 3)
        XCTAssertEqual(t.focusSeat, .C, "a pick into the center focuses it")
        assertSound(t)
    }

    func testPickFromAnotherSeatIsATradeEvenOnALockedSeat() {
        var t = threeUp
        t.locks = [.L]
        XCTAssertTrue(t.pick(2, into: .C))
        XCTAssertEqual(t.seats, [.L: 3, .C: 2, .R: 4])
        XCTAssertEqual(t.locks, [.L], "the lock stays with the seat")
        XCTAssertEqual(t.lastTrade, Trade(a: 2, b: 3, from: .L, to: .C))
        XCTAssertEqual(t.pile, threeUp.pile)
    }

    func testPickingTheCenterIntoAnEmptySatelliteRefillsTheCenter() {
        var t = Table(seats: [.C: 3, .R: 4], pile: [5])
        XCTAssertTrue(t.pick(3, into: .L))
        XCTAssertEqual(t.seats, [.L: 3, .C: 5, .R: 4])
        XCTAssertEqual(t.pile, [])
        var lone = Table(seats: [.C: 3])
        XCTAssertFalse(lone.pick(3, into: .L), "never leaves the center empty")
    }

    func testPickIgnoresUnknownAndHiddenWindowsAndTheCenterItself() {
        var t = threeUp
        t.holes = [.L: 9]
        XCTAssertFalse(t.pick(99, into: .C), "unknown")
        XCTAssertFalse(t.pick(9, into: .C), "hidden")
        XCTAssertFalse(t.pick(3, into: .C), "already there with focus")
        t.focusSeat = .R
        XCTAssertTrue(t.pick(3, into: .C), "already there: just focuses the center")
        XCTAssertEqual(t.focusSeat, .C)
        XCTAssertEqual(t.seats, threeUp.seats)
    }

    func testSummonSwapsAParkedWindowIntoTheCenterAndMovesNothingElse() {
        var t = threeUp
        t.focusSeat = .R
        XCTAssertEqual(t.summon(6), .C)
        XCTAssertEqual(t.seats, [.L: 2, .C: 6, .R: 4])
        XCTAssertEqual(t.focusSeat, .C)
        XCTAssertEqual(t.pile, [3, 5, 1, 7], "the old center tops the pile")
    }

    func testSummonInTwoUpLandsInTheLeftSeat() {
        var t = Table(seats: [.L: 1, .R: 2], pile: [3], focusSeat: .R, cols: 2)
        XCTAssertEqual(t.summon(3), .L)
        XCTAssertEqual(t.seats, [.L: 3, .R: 2])
        XCTAssertEqual(t.focusSeat, .L)
    }

    func testSummonSkipsALockedCenterAndIgnoresSeatedOrUnknownWindows() {
        var t = threeUp
        t.locks = [.C]
        XCTAssertEqual(t.summon(5), .R)
        XCTAssertEqual(t.seats, [.L: 2, .C: 3, .R: 5])
        XCTAssertNil(t.summon(2), "already visible")
        XCTAssertNil(t.summon(99), "unknown")
    }

    // MARK: - Focus

    func testFocusFollowMovesFocusToTheSeatWithoutMovingAnything() {
        var t = threeUp
        XCTAssertEqual(t.focusFollow(4), .R)
        XCTAssertEqual(t.seats, threeUp.seats)
        t.look(-1)
        XCTAssertEqual(t.focusSeat, .C, "J now steps from R, not from the stale C")
    }

    func testFocusFollowIgnoresParkedWindowsAndReachesALockedSeat() {
        var t = threeUp
        XCTAssertNil(t.focusFollow(5), "5 is parked")
        XCTAssertEqual(t.focusSeat, .C)
        t.locks = [.L]
        XCTAssertEqual(t.focusFollow(2), .L)
    }

    func testLookStepsAcrossOccupiedSeatsAndClampsAtTheEnds() {
        var t = Table(seats: [.C: 3, .R: 4], pile: [5])
        XCTAssertFalse(t.look(-1), "L is empty: C is the left end")
        XCTAssertTrue(t.look(1))
        XCTAssertEqual(t.focusSeat, .R)
        XCTAssertFalse(t.look(1))
        XCTAssertEqual(t.seats, [.C: 3, .R: 4], "looking moves nothing")
    }

    // MARK: - Lock

    func testLockTogglesTheFocusedSeatAndNeverAnEmptyOne() {
        var t = threeUp
        t.focusSeat = .R
        t.toggleLock()
        XCTAssertEqual(t.locks, [.R])
        XCTAssertEqual(t.focusSeat, .R, "focus stays on the seat just locked")
        t.toggleLock()
        XCTAssertEqual(t.locks, [])
        var empty = Table()
        XCTAssertFalse(empty.toggleLock(), "nothing to lock")
    }

    // MARK: - Pass (⌃⌥H / L)

    func testPassShiftsTheSeatsOneStepAndDrawsFromThePile() {
        var t = threeUp
        XCTAssertTrue(t.pass(1))
        XCTAssertEqual(t.seats, [.L: 3, .C: 4, .R: 5])
        XCTAssertEqual(t.pile, [2, 1, 6, 7], "the window passed off the left tops the pile")
        XCTAssertEqual(t.focusSeat, .C, "focus stays on its seat")
        XCTAssertTrue(t.pass(-1))
        XCTAssertEqual(t, threeUp, "pass(h) ∘ pass(l) = id")
    }

    func testHoldingPassCyclesTheColsPlusOneMostRecentCards() {
        var t = threeUp
        for _ in 0..<4 { t.pass(1) }
        XCTAssertEqual(t, threeUp)
        for _ in 0..<4 { t.pass(-1) }
        XCTAssertEqual(t, threeUp)
    }

    func testPassSkipsLockedAndEmptySeats() {
        var t = threeUp
        t.locks = [.C]
        t.pass(1)
        XCTAssertEqual(t.seats, [.L: 4, .C: 3, .R: 5], "C is locked: L and R pass around it")
        var gap = Table(seats: [.C: 3, .R: 4], pile: [5])
        gap.pass(1)
        XCTAssertEqual(gap.seats, [.C: 4, .R: 5], "a put-away seat stays empty")
        XCTAssertEqual(gap.pile, [3])
    }

    func testPassWithAnEmptyPileRotatesTheSeats() {
        var t = Table(seats: [.L: 1, .C: 2, .R: 3])
        t.pass(1)
        XCTAssertEqual(t.seats, [.L: 2, .C: 3, .R: 1])
        t.pass(-1)
        XCTAssertEqual(t.seats, [.L: 1, .C: 2, .R: 3])
        var lone = Table(seats: [.C: 1], cols: 1)
        XCTAssertFalse(lone.pass(1))
    }

    func testPassInMonocleTogglesLikeADraw() {
        var t = Table(seats: [.C: 1], pile: [2, 3], cols: 1)
        t.pass(1)
        XCTAssertEqual(t.seats, [.C: 2])
        t.pass(1)
        XCTAssertEqual(t.seats, [.C: 1])
    }

    func testPassDropsTheLastTrade() {
        var t = threeUp
        t.trade(with: .R)
        t.pass(1)
        XCTAssertNil(t.lastTrade)
    }

    // MARK: - Columns (⌃⌥1 / 2 / 3)

    func testGoingToMonocleCentersTheFocusedWindowAndPilesTheRest() {
        var t = threeUp
        t.focusSeat = .R
        XCTAssertTrue(t.setCols(1))
        XCTAssertEqual(t.seats, [.C: 4], "the focused window becomes C")
        XCTAssertEqual(t.pile, [3, 2, 5, 1, 6, 7], "the old C tops the pile, then the other satellite")
        XCTAssertEqual(t.focusSeat, .C)
        assertSound(t)
    }

    func testGoingToMonocleFromTheCenterPilesRightBeforeLeft() {
        var t = threeUp
        t.setCols(1)
        XCTAssertEqual(t.seats, [.C: 3])
        XCTAssertEqual(t.pile, [4, 2, 5, 1, 6, 7])
    }

    func testThreeToTwoMovesTheCenterIntoLeftAndKeepsTheFocusedSatellite() {
        var t = threeUp
        t.setCols(2)
        XCTAssertEqual(t.seats, [.L: 3, .R: 4], "C becomes the 2-up center; R stays")
        XCTAssertEqual(t.pile.first, 2)
        XCTAssertEqual(t.focusSeat, .L, "focus follows the window")

        var left = threeUp
        left.focusSeat = .L
        left.setCols(2)
        XCTAssertEqual(left.seats, [.L: 3, .R: 2], "the focused satellite stays visible")
        XCTAssertEqual(left.focusSeat, .R)
        XCTAssertEqual(left.pile.first, 4)
    }

    func testGrowingDrawsIntoRightThenLeft() {
        var mono = Table(seats: [.C: 1], pile: [2, 3, 4], cols: 1)
        mono.setCols(3)
        XCTAssertEqual(mono.seats, [.L: 3, .C: 1, .R: 2])
        XCTAssertEqual(mono.pile, [4])

        var two = Table(seats: [.L: 1, .R: 2], pile: [3, 4], focusSeat: .R, cols: 2)
        two.setCols(3)
        XCTAssertEqual(two.seats, [.L: 3, .C: 1, .R: 2], "L (the 2-up center) becomes C; R stays")
        XCTAssertEqual(two.focusSeat, .R)

        var oneToTwo = Table(seats: [.C: 1], pile: [2], cols: 1)
        oneToTwo.setCols(2)
        XCTAssertEqual(oneToTwo.seats, [.L: 1, .R: 2])
        assertSound(oneToTwo)
    }

    func testLocksSurviveColumnsOnlyOnSeatsThatKeepTheirWindow() {
        var t = threeUp
        t.locks = [.L, .R]
        t.trade(with: .C) // no-op: C is focused
        t.setCols(2)
        XCTAssertEqual(t.locks, [.R], "R keeps 4; L now shows the old center")
        XCTAssertNil(t.lastTrade)
    }

    func testColumnsMoveHolesWithTheirSeatsOrIntoThePile() {
        var t = Table(seats: [.C: 3, .R: 4], pile: [5], holes: [.L: 2])
        t.setCols(1)
        XCTAssertEqual(t.holes, [:])
        XCTAssertEqual(t.hidden, [2], "a hole whose seat goes away is set aside, not drawn")
        XCTAssertEqual(t.pile, [4, 5], "R's window joins the pile")
        assertSound(t)
    }

    func testInvalidOrUnchangedColumnsAreNoOps() {
        var t = threeUp
        XCTAssertFalse(t.setCols(3))
        XCTAssertFalse(t.setCols(4))
        XCTAssertEqual(t, threeUp)
    }
}

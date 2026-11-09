import XCTest
import CoreGraphics
@testable import StripCore

/// How the Table absorbs real windows appearing, closing, hiding and coming back
/// (`docs/design/seats-and-pile.md`, *Interactions*: new window, close, hide / minimize, restore).
final class TableWorldTests: XCTestCase {
    /// 3-up: L=2 C=3 R=4; pile 5, 1, 6, 7.
    private var threeUp: Table { Table(seats: [.L: 2, .C: 3, .R: 4], pile: [5, 1, 6, 7]) }

    private func assertSound(_ t: Table, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(t.invariantViolations(), [], file: file, line: line)
    }

    // MARK: - New windows

    func testAFocusedNewWindowTakesTheCenterAndTheOldCenterTopsThePile() {
        var t = threeUp
        t.focusSeat = .L
        XCTAssertEqual(t.add(9, focused: true), .C)
        XCTAssertEqual(t.seats, [.L: 2, .C: 9, .R: 4])
        XCTAssertEqual(t.pile.first, 3)
        XCTAssertEqual(t.focusSeat, .C)
        assertSound(t)
    }

    func testAFocusedNewWindowSkipsLockedSeatsRightThenLeft() {
        var t = threeUp
        t.locks = [.C]
        XCTAssertEqual(t.add(9, focused: true), .R)
        XCTAssertEqual(t.seats[.C], 3, "a locked seat keeps its window")
        t.locks = [.C, .R]
        XCTAssertEqual(t.add(10, focused: true), .L)
        t.locks = [.L, .C, .R]
        XCTAssertNil(t.add(11, focused: true), "every seat locked: the pile")
        XCTAssertEqual(t.pile.first, 11)
        assertSound(t)
    }

    func testABackgroundWindowTopsThePileOrJoinsItsBottom() {
        var t = threeUp
        XCTAssertNil(t.add(9, focused: false))
        XCTAssertEqual(t.pile, [9, 5, 1, 6, 7])
        XCTAssertNil(t.add(10, focused: false, atBottom: true))
        XCTAssertEqual(t.pile.last, 10)
        XCTAssertEqual(t.seats, threeUp.seats)
    }

    func testTheFirstWindowOfAnEmptyTableTakesTheCenter() {
        var t = Table()
        XCTAssertEqual(t.add(9, focused: false), .C)
        XCTAssertEqual(t.seats, [.C: 9])
        var two = Table(cols: 2)
        XCTAssertEqual(two.add(9, focused: false), .L)
        XCTAssertNil(t.add(9, focused: true), "already managed")
        assertSound(t)
    }

    // MARK: - Closing

    func testClosingAPileCardOrAHiddenWindowMovesNothing() {
        var t = threeUp
        t.holes = [.L: 8]
        t.seats[.L] = nil
        XCTAssertNil(t.remove(6))
        XCTAssertNil(t.remove(8))
        XCTAssertEqual(t.seats, [.C: 3, .R: 4])
        XCTAssertEqual(t.pile, [5, 1, 7])
        XCTAssertEqual(t.holes, [:])
    }

    func testAClosedSeatRefillsWithTheWindowMacOSFocusedElseTheTopOfThePile() {
        var t = threeUp
        XCTAssertEqual(t.remove(3, preferred: 6), 6, "macOS focused 6, a pile card")
        XCTAssertEqual(t.seats[.C], 6)
        XCTAssertEqual(t.pile, [5, 1, 7])
        XCTAssertEqual(t.remove(4, preferred: 2), 5, "2 is seated: pile[0] instead")
        XCTAssertEqual(t.seats, [.L: 2, .C: 6, .R: 5])
        assertSound(t)
    }

    func testALockedSatelliteIsNotRefilledAndLosesItsLock() {
        var t = threeUp
        t.locks = [.R]
        XCTAssertNil(t.remove(4))
        XCTAssertNil(t.seats[.R])
        XCTAssertEqual(t.locks, [])
        XCTAssertEqual(t.pile, threeUp.pile)
    }

    func testAnEmptyCenterPromotesTheMostRecentSatelliteWhenThePileIsEmpty() {
        var t = Table(seats: [.L: 2, .C: 3, .R: 4])
        XCTAssertEqual(t.remove(3, recent: [4, 2]), 4)
        XCTAssertEqual(t.seats, [.L: 2, .C: 4])
        var locked = Table(seats: [.L: 2, .C: 3, .R: 4], locks: [.R])
        XCTAssertEqual(locked.remove(3, recent: [4, 2]), 2, "unlocked satellites first")
        var onlyLocked = Table(seats: [.C: 3, .R: 4], locks: [.R])
        XCTAssertEqual(onlyLocked.remove(3), 4, "C must not stay empty: the lock gives way")
        XCTAssertEqual(onlyLocked.locks, [])
        var unknown = Table(seats: [.L: 2, .C: 3, .R: 4])
        XCTAssertEqual(unknown.remove(3), 4, "no recency: R, then L")
        assertSound(onlyLocked)
    }

    func testAnEmptySatelliteStaysEmptyWithAnEmptyPile() {
        var t = Table(seats: [.L: 2, .C: 3, .R: 4])
        XCTAssertNil(t.remove(4))
        XCTAssertEqual(t.seats, [.L: 2, .C: 3])
    }

    func testClosingTheLastWindowLeavesASoundEmptyTableAndDropsTheLastTrade() {
        var t = Table(seats: [.C: 3, .R: 4], focusSeat: .R)
        t.trade(with: .C)
        t.remove(4)
        XCTAssertNil(t.lastTrade)
        t.remove(3)
        XCTAssertTrue(t.members.isEmpty)
        assertSound(t)
    }

    // MARK: - Hide and restore

    func testAHiddenSatelliteLeavesAHoleAndNothingRefillsIt() {
        var t = threeUp
        XCTAssertNil(t.hide(4))
        XCTAssertNil(t.seats[.R])
        XCTAssertEqual(t.holes, [.R: 4])
        XCTAssertEqual(t.pile, threeUp.pile)
        assertSound(t)
    }

    func testAHiddenCenterIsAHoleAndIsRefilled() {
        var t = threeUp
        XCTAssertEqual(t.hide(3, preferred: 6), 6)
        XCTAssertEqual(t.seats[.C], 6)
        XCTAssertEqual(t.holes, [.C: 3])
        assertSound(t)
    }

    func testAHiddenPileCardIsSetAsideAndNeverDrawn() {
        var t = threeUp
        t.hide(5)
        XCTAssertEqual(t.pile, [1, 6, 7])
        XCTAssertEqual(t.hidden, [5])
        t.draw(into: .R)
        XCTAssertEqual(t.seats[.R], 1, "the draw skips the minimized window")
        XCTAssertFalse(t.pick(5, into: .C), "nor can it be picked")
        t.remove(3)
        XCTAssertEqual(t.seats[.C], 4, "nor refill a seat")
        assertSound(t)
    }

    func testARestoredWindowRetakesItsSeatAndTheRefillTopsThePile() {
        var t = threeUp
        t.hide(3)
        XCTAssertEqual(t.seats[.C], 5)
        XCTAssertEqual(t.restore(3), .C)
        XCTAssertEqual(t.seats, threeUp.seats)
        XCTAssertEqual(t.pile, threeUp.pile)
        XCTAssertEqual(t.holes, [:])

        var r = threeUp
        r.hide(4)
        XCTAssertEqual(r.restore(4), .R)
        XCTAssertEqual(r, threeUp, "a satellite hole: back where it was")
    }

    func testARestoredPileCardIsSummoned() {
        var t = threeUp
        t.hide(6)
        XCTAssertEqual(t.restore(6), .C)
        XCTAssertEqual(t.seats[.C], 6)
        XCTAssertEqual(t.pile.first, 3)
    }

    // MARK: - Native tabs

    func testReplaceSwapsTheIdWhereverItIs() {
        var t = threeUp
        t.holes = [.L: 8]
        t.seats[.L] = nil
        XCTAssertTrue(t.replace(3, with: 30))
        XCTAssertTrue(t.replace(8, with: 80))
        XCTAssertTrue(t.replace(6, with: 60))
        XCTAssertEqual(t.seats, [.C: 30, .R: 4])
        XCTAssertEqual(t.holes, [.L: 80])
        XCTAssertEqual(t.pile, [5, 1, 60, 7])
        XCTAssertFalse(t.replace(99, with: 100), "unknown")
        XCTAssertFalse(t.replace(30, with: 4), "already managed")
    }

    // MARK: - Startup adoption

    func testAdoptionSeatsWindowsAlreadyInASeatThenTheFocusedThenFrontToBack() {
        let stage = Stage(vis: CGRect(x: 0, y: 25, width: 3440, height: 1415))
        var t = Table()
        let rects = t.seatRects(on: stage)
        let elsewhere = CGRect(x: 300, y: 300, width: 1000, height: 800)
        t.adopt([(1, elsewhere), (2, elsewhere), (3, rects[.R]!), (4, elsewhere), (5, elsewhere)],
                focused: 4, on: stage)
        XCTAssertEqual(t.seats, [.L: 1, .C: 4, .R: 3], "3 was in R; 4 has focus; 1 is frontmost after it")
        XCTAssertEqual(t.pile, [2, 5])
        XCTAssertEqual(t.focusSeat, .C)
        assertSound(t)
    }

    // MARK: - Random walk

    /// World operations mixed with the verbs keep every invariant, never lose or invent a window,
    /// and never change what a locked seat shows, except to keep the center filled or to give a
    /// restored window its own seat back.
    func testARandomWalkOfWindowsComingAndGoingKeepsEveryInvariant() {
        var rng = SplitMix64(seed: 0xF00D)
        for _ in 0..<150 {
            var t = Table(cols: Int(rng.next() % 3) + 1)
            var next: CGWindowID = 1
            var hidden = Set<CGWindowID>()
            for _ in 0..<60 {
                let before = t
                var expected = Set(t.members)
                var touched: CGWindowID?
                switch rng.next() % 9 {
                case 0, 1:
                    t.add(next, focused: rng.next() % 2 == 0, atBottom: rng.next() % 4 == 0)
                    expected.insert(next)
                    next += 1
                case 2:
                    if let id = t.members.randomElement(using: &rng) {
                        t.remove(id, preferred: t.pile.randomElement(using: &rng), recent: t.seated.shuffled(using: &rng))
                        expected.remove(id)
                        hidden.remove(id)
                        touched = id
                    }
                case 3:
                    if let id = t.members.filter({ !hidden.contains($0) }).randomElement(using: &rng) {
                        t.hide(id, preferred: t.pile.randomElement(using: &rng))
                        hidden.insert(id)
                        touched = id
                    }
                case 4:
                    if let id = hidden.randomElement(using: &rng) {
                        t.restore(id)
                        hidden.remove(id)
                        touched = id
                    }
                case 5: t.draw(into: t.slots.randomElement(using: &rng)!)
                case 6: t.pass(rng.next() % 2 == 0 ? 1 : -1)
                case 7: t.toggleLock()
                default: t.setCols(Int(rng.next() % 3) + 1)
                }
                XCTAssertEqual(t.invariantViolations(), [], "from \(before)")
                XCTAssertEqual(Set(t.members), expected)
                if t.cols == before.cols, let touched {
                    for s in before.locks where s != t.primary && before.seats[s] != touched && before.hole(of: touched) != s {
                        if t.locks.contains(s) {
                            XCTAssertEqual(t.seats[s], before.seats[s], "locked \(s) changed by a world operation")
                        }
                    }
                }
            }
        }
    }
}

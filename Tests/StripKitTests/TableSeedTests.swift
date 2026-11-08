import XCTest
import CoreGraphics
@testable import StripKit

/// Seats & Pile migration (`StripState.table`): the Table step 3 starts from shows exactly what the
/// ring shows, with the pile ordered recency first, then ring distance. The pile cases are ported
/// from `StripStateTests` (step 1).
final class TableSeedTests: XCTestCase {
    let ring: [CGWindowID] = [1, 2, 3, 4, 5, 6, 7]
    /// 3-up, ring 1…7 centered on 3: L=2 C=3 R=4; 5, 6, 7, 1 parked.
    private var threeUp: StripState { StripState(ring: ring, centerId: 3, cols: 3, focusSlot: .C) }

    func testSeatsAreWhatTheRingShows() {
        let t = threeUp.table
        XCTAssertEqual(t.seats, [.L: 2, .C: 3, .R: 4])
        XCTAssertEqual(t.focusSeat, .C)
        XCTAssertEqual(t.invariantViolations(), [])
    }

    func testThePileSeedsFromTheRingNearestTheCenterFirst() {
        XCTAssertEqual(threeUp.table.pile, [5, 1, 6, 7], "distance 2 (right, then left), then distance 3")
    }

    func testThePileFollowsRecencyBeforeRingDistance() {
        var s = threeUp
        s.mru = [6, 3, 7]
        XCTAssertEqual(s.table.pile, [6, 7, 5, 1], "seated 3 is skipped; unknown windows follow by distance")
    }

    func testPinsBecomeLocksAndFocusAndTheLastTradeCarryOver() {
        var s = threeUp
        s.pins = [.R: 4]
        s.focusSlot = .R
        s.lastTrade = Trade(a: 3, b: 2, from: .C, to: .L)
        let t = s.table
        XCTAssertEqual(t.locks, [.R])
        XCTAssertEqual(t.focusSeat, .R)
        XCTAssertEqual(t.lastTrade, s.lastTrade)
    }

    func testFewerWindowsThanSeatsSeatEachWindowOnce() {
        let two = StripState(ring: [1, 2], centerId: 1, cols: 3, focusSlot: .L).table
        XCTAssertEqual(two.seats, [.C: 1, .R: 2], "the ring's assignment would repeat a window")
        XCTAssertEqual(two.focusSeat, .C, "focus moves off the empty L")
        XCTAssertEqual(two.invariantViolations(), [])
        XCTAssertEqual(StripState().table, Table(), "an empty ring is an empty table")
    }

    func testEverySeededTableIsSound() {
        for cols in 1...3 {
            for n in 0...7 {
                for center in [nil] + (0..<n).map({ CGWindowID($0 + 1) }) {
                    let s = StripState(ring: Array(CGWindowID(1)...CGWindowID(max(n, 1))).prefix(n).map { $0 },
                                       centerId: center, cols: cols)
                    let t = s.table
                    XCTAssertEqual(t.invariantViolations(), [], "\(n) windows, \(cols)-up, center \(String(describing: center))")
                    XCTAssertEqual(Set(t.members), Set(s.ring), "a window was lost")
                }
            }
        }
    }
}

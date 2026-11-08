import XCTest
import CoreGraphics
@testable import StripCore

/// The design doc's invariants (*Pure state*, "each one a unit test"): each structural invariant is
/// detected when broken, the verb invariants hold for every table, and a seeded random walk over all
/// verbs never produces an unsound table.
final class TableInvariantTests: XCTestCase {
    // MARK: - Detection

    func testASoundTableHasNoViolations() {
        XCTAssertEqual(Table().invariantViolations(), [], "an empty table is sound")
        XCTAssertEqual(Table(seats: [.L: 2, .C: 3, .R: 4], pile: [5], holes: [.L: 9], locks: [.R]).invariantViolations(), [])
    }

    func testEveryWindowIsInExactlyOnePlace() {
        let both = Table(seats: [.C: 3], pile: [3])
        XCTAssertEqual(both.invariantViolations(), ["window 3 is in 2 places"])
        let twice = Table(seats: [.L: 3, .C: 3])
        XCTAssertEqual(twice.invariantViolations(), ["window 3 is in 2 places"])
        let hidden = Table(seats: [.C: 3], pile: [4], holes: [.L: 4])
        XCTAssertEqual(hidden.invariantViolations(), ["window 4 is in 2 places"])
    }

    func testTheCenterIsNeverEmptyWhileAnyCardExists() {
        XCTAssertEqual(Table(seats: [.R: 4], focusSeat: .R).invariantViolations(),
                       ["the primary seat C is empty while cards exist"])
        XCTAssertEqual(Table(pile: [5]).invariantViolations(), ["the primary seat C is empty while cards exist"])
        XCTAssertEqual(Table(seats: [.R: 4], focusSeat: .R, cols: 2).invariantViolations(),
                       ["the primary seat L is empty while cards exist"], "in 2-up L is the center")
        XCTAssertEqual(Table(holes: [.C: 3]).invariantViolations(), [], "only a hidden window: nothing to show")
    }

    func testSeatsHolesLocksAndFocusMustExistForTheColumnCount() {
        let t = Table(seats: [.C: 3, .R: 4], holes: [.L: 2], locks: [.R], focusSeat: .R, cols: 1)
        XCTAssertEqual(t.invariantViolations(), [
            "seat R doesn't exist in 1-up",
            "hole L doesn't exist in 1-up",
            "lock R doesn't exist in 1-up",
            "focus is on R, which doesn't exist in 1-up",
        ])
        XCTAssertEqual(Table(seats: [.C: 3], focusSeat: .R).invariantViolations(), ["focus is on the empty seat R"])
        XCTAssertEqual(Table(cols: 4).invariantViolations(), ["cols 4 is not 1–3"])
    }

    func testTheLastTradeNamesManagedWindows() {
        let t = Table(seats: [.C: 3], lastTrade: Trade(a: 3, b: 99, from: .C, to: .R))
        XCTAssertEqual(t.invariantViolations(), ["lastTrade names a window that isn't managed"])
    }

    // MARK: - Verb invariants

    /// trade ∘ trade = id: trading back from the seat focus moved to restores the table.
    func testTradeIsItsOwnInverseForEveryPairOfSeats() {
        for cols in [2, 3] {
            let base = Table(seats: cols == 3 ? [.L: 1, .C: 2, .R: 3] : [.L: 1, .R: 2], pile: [7, 8], cols: cols)
            for from in base.slots {
                for to in base.slots where to != from {
                    var t = base
                    t.focusSeat = from
                    XCTAssertTrue(t.trade(with: to))
                    XCTAssertTrue(t.trade(with: from))
                    var expected = base
                    expected.focusSeat = from
                    expected.lastTrade = t.lastTrade
                    XCTAssertEqual(t, expected, "\(cols)-up \(from)↔\(to)")
                }
            }
        }
    }

    /// pass(h) ∘ pass(l) = id and pass(l) ∘ pass(h) = id, with and without a pile and locks.
    func testPassBackUndoesPassOnEveryTable() {
        let tables = [
            Table(seats: [.L: 1, .C: 2, .R: 3], pile: [4, 5]),
            Table(seats: [.L: 1, .C: 2, .R: 3]),
            Table(seats: [.L: 1, .C: 2, .R: 3], pile: [4], locks: [.L]),
            Table(seats: [.C: 2, .R: 3], pile: [4, 5]),
            Table(seats: [.L: 1, .R: 2], pile: [3], cols: 2),
            Table(seats: [.C: 1], pile: [2, 3], cols: 1),
        ]
        for base in tables {
            for dir in [1, -1] {
                var t = base
                guard t.pass(dir) else { continue }
                XCTAssertTrue(t.pass(-dir))
                XCTAssertEqual(t, base, "pass(\(-dir)) ∘ pass(\(dir)) on \(base.seats)")
            }
        }
    }

    // MARK: - Random walk

    /// Every verb, applied in a seeded random order to random tables, keeps every invariant, and the
    /// operations that run automatically or skip locks (pass, trade, promote) never change what a
    /// locked seat shows.
    func testARandomWalkOverEveryVerbKeepsEveryInvariant() {
        var rng = SplitMix64(seed: 0x5EA75)
        var steps = 0
        for _ in 0..<200 {
            var t = randomTable(&rng)
            XCTAssertEqual(t.invariantViolations(), [], "seed table \(t)")
            for _ in 0..<40 {
                let before = t
                let verb = Int(rng.next() % 12)
                switch verb {
                case 0: t.draw(into: t.slots.randomElement(using: &rng)!)
                case 1: t.trade(with: t.slots.randomElement(using: &rng)!)
                case 2: t.promote()
                case 3: if let id = t.members.randomElement(using: &rng) { t.promote(id) }
                case 4: if let id = t.members.randomElement(using: &rng) { t.pick(id, into: t.slots.randomElement(using: &rng)!) }
                case 5: if let id = t.pile.randomElement(using: &rng) { t.summon(id) }
                case 6: if let id = t.members.randomElement(using: &rng) { t.focusFollow(id) }
                case 7: t.look(Bool.random(using: &rng) ? 1 : -1)
                case 8: t.toggleLock()
                case 9: t.pass(Bool.random(using: &rng) ? 1 : -1)
                case 10: t.setCols(Int.random(in: 1...3, using: &rng))
                default: t.emphasis = t.emphasis == .focus ? .equal : .focus
                }
                steps += 1
                XCTAssertEqual(t.invariantViolations(), [], "verb \(verb) from \(before)")
                XCTAssertEqual(Set(t.members), Set(before.members), "verb \(verb) lost or invented a window")
                if [1, 2, 3, 9].contains(verb) {
                    for s in before.locks where t.cols == before.cols {
                        XCTAssertEqual(t.seats[s], before.seats[s], "verb \(verb) changed locked seat \(s)")
                    }
                }
            }
        }
        XCTAssertEqual(steps, 8000)
    }

    private func randomTable(_ rng: inout SplitMix64) -> Table {
        let cols = Int.random(in: 1...3, using: &rng)
        let slots = Table.slots(cols: cols)
        var ids = Array(CGWindowID(1)...CGWindowID(UInt32.random(in: 1...9, using: &rng))).shuffled(using: &rng)
        var t = Table(cols: cols)
        t.seats[t.primary] = ids.removeFirst()
        for s in slots where s != t.primary && !ids.isEmpty && Bool.random(using: &rng) {
            t.seats[s] = ids.removeFirst()
        }
        for s in slots where !ids.isEmpty && rng.next() % 5 == 0 {
            if s == t.primary || t.seats[s] == nil { t.holes[s] = ids.removeFirst() }
        }
        t.pile = ids
        t.locks = Set(slots.filter { t.seats[$0] != nil && rng.next() % 4 == 0 })
        t.focusSeat = slots.filter { t.seats[$0] != nil }.randomElement(using: &rng) ?? t.primary
        return t
    }
}

/// A small deterministic generator (SplitMix64) so random-walk failures reproduce from the seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

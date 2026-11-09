import XCTest
import CoreGraphics
@testable import StripCore

/// The reducer's command path (Seats & Pile step 2, commit 3). Each interaction-table row for a
/// command (`docs/design/seats-and-pile.md`, *Interactions*, "Windows moved") is asserted on the
/// plan the reducer returns, together with its focus hand-off, render, save and log effects.
final class ReducerCommandTests: XCTestCase {
    let stage = Stage(vis: CGRect(x: 0, y: 25, width: 3440, height: 1415))

    /// 3-up: L=2 C=3 R=4; pile 5, 1, 6, 7; the center window already has keyboard focus.
    private var threeUp: CoreState {
        var s = CoreState(table: Table(seats: [.L: 2, .C: 3, .R: 4], pile: [5, 1, 6, 7]), stage: stage)
        s.handedFocus = 3
        return s
    }

    private func reduce(_ s: CoreState, _ c: Command, at now: CFTimeInterval = 0, repeated: Bool = false) -> Reduction {
        Reducer.reduce(s, .chord(c, repeated: repeated), now: now)
    }

    private func tick(_ s: CoreState, at now: CFTimeInterval) -> Reduction {
        Reducer.reduce(s, .tick, now: now)
    }

    /// Ids of the steps of `kind`, sorted.
    private func ids(_ p: MovePlan, _ kind: MoveKind) -> [CGWindowID] {
        p.steps(kind).map(\.id).sorted()
    }

    /// Where a frame sits along the row: −1 parked left, 0…n−1 the seats, n parked right.
    private func position(_ r: CGRect, on t: Table) -> Int {
        if r.maxX <= stage.vis.minX { return -1 }
        if r.minX >= stage.vis.maxX { return t.slots.count }
        let rects = t.seatRects(on: stage)
        return t.slots.firstIndex { rects[$0]!.contains(CGPoint(x: r.midX, y: r.midY)) } ?? -99
    }

    /// Every spring in `r.plan` moves its window by at most one seat (parks count as positions).
    private func assertOneSeatEach(_ before: CoreState, _ r: Reduction, file: StaticString = #filePath, line: UInt = #line) {
        let was = before.table.targets(on: stage, parkEdges: before.parkEdges)
        for s in r.plan.steps(.spring) {
            let from = before.lastTargets[s.id] ?? was[s.id]!
            let d = abs(position(s.frame, on: r.state.table) - position(from, on: before.table))
            XCTAssertLessThanOrEqual(d, 1, "window \(s.id) moves \(d) seats", file: file, line: line)
        }
    }

    private func logs(_ r: Reduction) -> [LogLine] {
        r.effects.compactMap { if case let .log(l) = $0 { return l } else { return nil } }
    }

    private func focuses(_ r: Reduction) -> [CGWindowID] {
        r.effects.compactMap { if case let .focus(id) = $0 { return id } else { return nil } }
    }

    // MARK: - Draw: "2, cut"

    func testDrawIntoASatelliteIsTwoCutsAndActivatesNothing() {
        let r = reduce(threeUp, .draw(.o))
        XCTAssertEqual(ids(r.plan, .cut), [4, 5])
        XCTAssertEqual(r.plan.steps(.spring), [])
        XCTAssertEqual(r.effects, [.log(.draw(drawn: 5, displaced: 4, seat: .R)), .render],
                       "focus stays in C: no hand-off, no wake")
        XCTAssertNil(r.state.pending.focusHandOff)
    }

    func testSwappingTheCenterIsTwoCutsThenHandsFocusToTheDrawnWindow() {
        let r = reduce(threeUp, .draw(.i))
        XCTAssertEqual(ids(r.plan, .cut), [3, 5])
        XCTAssertEqual(r.effects, [.log(.draw(drawn: 5, displaced: 3, seat: .C)), .render, .wake(at: Timing.focusSettle)])
        XCTAssertEqual(tick(r.state, at: 0.1).effects, [], "not yet")
        let settled = tick(r.state, at: Timing.focusSettle)
        XCTAssertEqual(settled.effects, [.focus(5)])
        XCTAssertEqual(settled.state.handedFocus, 5)
        XCTAssertTrue(settled.plan.isEmpty)
    }

    func testDrawingBackBeforeTheSettleCancelsTheHandOff() {
        let first = reduce(threeUp, .draw(.i))
        let back = reduce(first.state, .draw(.i), at: 0.05)
        XCTAssertEqual(back.state.table.seats[.C], 3, "⌃⌥I again flips back")
        XCTAssertNil(back.state.pending.focusHandOff, "3 already has focus")
        XCTAssertEqual(tick(back.state, at: 0.3).effects, [])
    }

    // MARK: - Trade: "2: spring for neighbors, cut for L↔R"

    func testANeighborTradeIsTwoSpringsOneSeatEachAndFocusTravelsWithTheWindow() {
        let r = reduce(threeUp, .trade(.o))
        XCTAssertEqual(ids(r.plan, .spring), [3, 4])
        XCTAssertEqual(r.plan.steps.count, 2)
        assertOneSeatEach(threeUp, r)
        XCTAssertEqual(r.state.table.focusedId, 3)
        XCTAssertNil(r.state.pending.focusHandOff, "the focused window kept focus; nothing to activate")
        XCTAssertEqual(logs(r), [.trade(.trade, Trade(a: 3, b: 4, from: .C, to: .R), cut: false, cause: .tradeKey(.o))])
    }

    func testALeftRightTradeIsTwoCuts() {
        var s = threeUp
        s.table.focusSeat = .L
        s.handedFocus = 2
        let r = reduce(s, .trade(.o))
        XCTAssertEqual(ids(r.plan, .cut), [2, 4])
        XCTAssertEqual(r.plan.steps.count, 2)
        XCTAssertEqual(logs(r), [.trade(.trade, Trade(a: 2, b: 4, from: .L, to: .R), cut: true, cause: .tradeKey(.o))])
    }

    // MARK: - Promote: "2, about 1 seat each"

    func testPromoteSpringsAndItsUndoHandsFocusToTheWindowBackInTheCenter() {
        var s = threeUp
        s.table.focusSeat = .R
        s.handedFocus = 4
        let promoted = reduce(s, .promote)
        XCTAssertEqual(ids(promoted.plan, .spring), [3, 4])
        assertOneSeatEach(s, promoted)
        XCTAssertNil(promoted.state.pending.focusHandOff)

        let undone = reduce(promoted.state, .promote, at: 1)
        XCTAssertEqual(undone.state.table.seats[.C], 3)
        XCTAssertEqual(logs(undone).first, .trade(.promoteUndo, Trade(a: 4, b: 3, from: .C, to: .R), cut: false, cause: .promoteKey))
        XCTAssertEqual(undone.state.pending.focusHandOff, Deadline(3, at: 1 + Timing.focusSettle))
    }

    // MARK: - No-ops

    func testRefusedCommandsMoveNothingAndOnlyLog() {
        let empty = CoreState(table: Table(seats: [.L: 1, .C: 2, .R: 3]), stage: stage)
        XCTAssertEqual(reduce(empty, .draw(.o)), Reduction(state: empty, plan: .none, effects: [.log(.drawEmpty(seat: .R))]))
        XCTAssertEqual(reduce(threeUp, .trade(.i)).effects, [.log(.tradeNoOp(focus: .C, target: .C))])
        XCTAssertEqual(reduce(threeUp, .promote).effects, [.log(.promoteNoOp(undo: true))])
        XCTAssertEqual(reduce(threeUp, .pick(99, into: nil)).effects, [.log(.pickNoOp(99))])
        XCTAssertEqual(reduce(threeUp, .setCols(3)).effects, [])
        XCTAssertTrue(reduce(threeUp, .look(-1)).plan.isEmpty)
    }

    // MARK: - Pick: "2 (cut from the pile; spring for neighbors; cut for L↔R)"

    func testAPickFromThePileIntoTheCenterIsTwoCutsAndFocusesIt() {
        let r = reduce(threeUp, .pick(6, into: nil))
        XCTAssertEqual(ids(r.plan, .cut), [3, 6])
        XCTAssertEqual(logs(r), [.pick(6, seat: .C, displaced: 3)])
        XCTAssertEqual(r.state.pending.focusHandOff?.value, 6)
    }

    func testAPickIntoASatelliteLeavesFocusAlone() {
        let r = reduce(threeUp, .pick(6, into: .u))
        XCTAssertEqual(ids(r.plan, .cut), [2, 6])
        XCTAssertNil(r.state.pending.focusHandOff)
    }

    func testAPickFromAnotherSeatIsATrade() {
        let r = reduce(threeUp, .pick(2, into: .i))
        XCTAssertEqual(ids(r.plan, .spring), [2, 3])
        XCTAssertEqual(logs(r), [.trade(.pick, Trade(a: 2, b: 3, from: .L, to: .C), cut: false, cause: .pick)])
        XCTAssertEqual(r.state.pending.focusHandOff?.value, 2)
        let lr = reduce(threeUp, .pick(2, into: .o))
        XCTAssertEqual(ids(lr.plan, .cut), [2, 4], "L↔R cuts")
    }

    // MARK: - Pass: "4, 1 seat each (the only fan-out)"

    func testPassIsFourSpringsOneSeatEachAndFocusesTheNewCenter() {
        let r = reduce(threeUp, .pass(1))
        XCTAssertEqual(ids(r.plan, .spring), [2, 3, 4, 5])
        XCTAssertEqual(r.plan.steps.count, 4)
        assertOneSeatEach(threeUp, r)
        XCTAssertEqual(r.state.pending.focusHandOff?.value, 4)
        XCTAssertEqual(r.effects.first, .render)
    }

    func testPassInMonocleIsADrawToggle() {
        var s = CoreState(table: Table(seats: [.C: 1], pile: [2, 3], cols: 1), stage: stage)
        s.handedFocus = 1
        let r = reduce(s, .pass(1))
        XCTAssertEqual(ids(r.plan, .cut), [1, 2])
        XCTAssertEqual(r.plan.steps(.spring), [], "nothing slides across the monocle window")
    }

    func testFramesAndParkEdgesCarryIntoTheNextPlan() {
        let there = reduce(threeUp, .pass(1))
        XCTAssertEqual(there.state.parkEdges[2], .left, "2 left off the left edge")
        XCTAssertLessThan(there.state.lastTargets[2]!.maxX, stage.vis.minX)
        let back = reduce(there.state, .pass(-1), at: 1)
        XCTAssertEqual(back.state.table, threeUp.table)
        XCTAssertEqual(back.plan.phases.count, 1, "2 slides back in from where it parked: no prepare snap")
        XCTAssertEqual(ids(back.plan, .spring), [2, 3, 4, 5])
        assertOneSeatEach(there.state, back)
    }

    // MARK: - Look and lock: "0"

    func testLookMovesNothingAndHandsFocusOver() {
        let r = reduce(threeUp, .look(1))
        XCTAssertTrue(r.plan.isEmpty)
        XCTAssertEqual(r.effects, [.render, .wake(at: Timing.focusSettle)])
        XCTAssertEqual(tick(r.state, at: 1).effects, [.focus(4)])
    }

    func testLockMovesNothingAndActivatesNothing() {
        let r = reduce(threeUp, .lock)
        XCTAssertTrue(r.plan.isEmpty)
        XCTAssertEqual(r.effects, [.render])
        XCTAssertEqual(r.state.table.locks, [.C])
    }

    // MARK: - Columns: "up to 2 cuts, plus C resized in place"

    func testColumnsCutAtMostTwoWindowsResizeTheCenterInPlaceAndSave() {
        let mono = reduce(threeUp, .setCols(1))
        XCTAssertEqual(ids(mono.plan, .cut), [2, 4])
        XCTAssertEqual(ids(mono.plan, .spring), [3])
        XCTAssertTrue(mono.effects.contains(.persist))

        let grow = reduce(mono.state, .setCols(3), at: 1)
        XCTAssertEqual(ids(grow.plan, .cut), [2, 4], "pile[0] into R, pile[1] into L")
        XCTAssertEqual(ids(grow.plan, .spring), [3])
        XCTAssertEqual(grow.state.table.seats, threeUp.table.seats)
    }

    // MARK: - Layout knobs

    func testEmphasisSpringsTheSeatsInPlaceAndSaves() {
        let r = reduce(threeUp, .toggleEmphasis)
        XCTAssertEqual(ids(r.plan, .spring), [2, 3, 4])
        XCTAssertEqual(r.plan.steps(.cut), [])
        XCTAssertTrue(r.plan.steps(.snap).allSatisfy { !$0.frame.intersects(stage.vis) },
                      "parked cards are sized like the end seat, so they resize too, off screen")
        XCTAssertEqual(r.effects, [.render, .persist])
        XCTAssertEqual(reduce(r.state, .setEmphasis(.equal)).effects, [], "already equal")
    }

    func testTheFocusKnobsAdjustTheShareOrTheMonocleWidthAndClamp() {
        let wider = reduce(threeUp, .adjustFocusRatio(0.05))
        XCTAssertEqual(wider.state.table.config.focusRatio, 0.55, accuracy: 1e-9)
        XCTAssertEqual(logs(wider), [.focusRatio(wider.state.table.config.focusRatio)])
        XCTAssertEqual(ids(wider.plan, .spring), [2, 3, 4])

        let mono = reduce(threeUp, .setCols(1)).state
        let filled = reduce(mono, .adjustFocusRatio(5))
        XCTAssertEqual(filled.state.table.config.monocleWidthFraction, LayoutConfig.monocleWidthRange.upperBound)
        XCTAssertEqual(logs(filled), [.monocleWidth(1)])

        let gap = reduce(threeUp, .adjustGap(-100))
        XCTAssertEqual(logs(gap), [.gap(inner: 0, outer: 0)], "floored at 0")
        let short = reduce(threeUp, .adjustHeight(-1))
        XCTAssertEqual(short.state.table.config.heightFraction, LayoutConfig.heightRange.lowerBound)
    }

    // MARK: - Held keys

    func testAHeldPassIsPacedAndTheLatestDirectionWins() {
        let fresh = reduce(threeUp, .pass(1))
        XCTAssertFalse(fresh.plan.isEmpty, "a fresh press acts now")
        let held = reduce(fresh.state, .pass(1), at: 0.05, repeated: true)
        XCTAssertTrue(held.plan.isEmpty, "too soon: queued")
        XCTAssertEqual(held.state.pending.nav, Deadline(.pass(1), at: Timing.navInterval))
        let turned = reduce(held.state, .pass(-1), at: 0.1, repeated: true)
        XCTAssertEqual(turned.state.pending.nav, Deadline(.pass(-1), at: Timing.navInterval), "latest wins, same slot")

        let handOff = tick(turned.state, at: Timing.focusSettle)
        XCTAssertEqual(handOff.effects, [.focus(4), .wake(at: Timing.navInterval)])
        let step = tick(handOff.state, at: Timing.navInterval)
        XCTAssertEqual(step.state.table, threeUp.table, "the queued pass(-1) ran")
        XCTAssertNil(step.state.pending.nav)
    }

    func testAFreshPressDropsAQueuedHeldStep() {
        let fresh = reduce(threeUp, .look(1))
        let held = reduce(fresh.state, .look(1), at: 0.05, repeated: true)
        XCTAssertNotNil(held.state.pending.nav)
        let press = reduce(held.state, .look(-1), at: 0.1)
        XCTAssertNil(press.state.pending.nav)
        XCTAssertEqual(press.state.table.focusSeat, .C)
    }

    func testARepeatAfterTheIntervalRunsAtOnce() {
        let fresh = reduce(threeUp, .look(1))
        let later = reduce(fresh.state, .look(-1), at: 0.25, repeated: true)
        XCTAssertEqual(later.state.table.focusSeat, .C)
        XCTAssertNil(later.state.pending.nav)
    }

    func testAHeldDrawIsNotPaced() {
        let first = reduce(threeUp, .draw(.o))
        let again = reduce(first.state, .draw(.o), at: 0.01, repeated: true)
        XCTAssertEqual(again.state.table.seats[.R], 4, "every repeat draws, as today")
    }

    // MARK: - Wake

    func testAWakeIsEmittedOnlyWhenTheEarliestDeadlineChanges() {
        let a = reduce(threeUp, .look(1))
        XCTAssertTrue(a.effects.contains(.wake(at: Timing.focusSettle)))
        let b = reduce(a.state, .lock, at: 0.05)
        XCTAssertFalse(b.effects.contains { if case .wake = $0 { return true } else { return false } })
        let c = reduce(b.state, .look(-1), at: 0.1)
        XCTAssertNil(c.state.pending.focusHandOff, "back on the window that has focus")
        XCTAssertFalse(c.effects.contains { if case .wake = $0 { return true } else { return false } },
                       "nothing left to wake for; the old timer's tick is harmless")
        XCTAssertEqual(tick(c.state, at: Timing.focusSettle).effects, [])
    }

    // MARK: - Properties

    func testTheReducerIsDeterministic() {
        var s = threeUp
        var rng = SplitMix64(seed: 7)
        var t: CFTimeInterval = 0
        for _ in 0..<50 {
            t += Double(rng.next() % 300) / 1000
            let c = randomCommand(&rng, s.table)
            let r1 = reduce(s, c, at: t), r2 = reduce(s, c, at: t)
            XCTAssertEqual(r1, r2)
            s = r1.state
        }
    }

    /// Random commands and ticks keep the table sound, keep the commanded frames and park edges to
    /// managed windows, park every pile card off screen, and only ever hand focus to the focused
    /// seat's window.
    func testARandomRunOfCommandsKeepsTheStateSound() {
        var rng = SplitMix64(seed: 0xD1CE)
        for _ in 0..<60 {
            var s = threeUp
            var t: CFTimeInterval = 0
            for _ in 0..<60 {
                t += Double(rng.next() % 250) / 1000
                let r = rng.next() % 4 == 0
                    ? tick(s, at: t)
                    : reduce(s, randomCommand(&rng, s.table), at: t, repeated: rng.next() % 3 == 0)
                s = r.state
                XCTAssertEqual(s.table.invariantViolations(), [])
                let members = Set(s.table.members)
                XCTAssertTrue(Set(s.lastTargets.keys).isSubset(of: members))
                XCTAssertEqual(Set(s.parkEdges.keys), Set(s.table.pile))
                for id in s.table.pile {
                    if let f = s.lastTargets[id] { XCTAssertFalse(f.intersects(stage.vis), "pile card \(id) on screen") }
                }
                for id in focuses(r) { XCTAssertEqual(id, s.table.focusedId) }
            }
        }
    }

    private func randomCommand(_ rng: inout SplitMix64, _ t: Table) -> Command {
        let key = SeatKey.allCases[Int(rng.next() % 3)]
        let dir = rng.next() % 2 == 0 ? 1 : -1
        switch rng.next() % 11 {
        case 0: return .draw(key)
        case 1: return .trade(key)
        case 2: return .promote
        case 3: return .pick(t.members.isEmpty ? 1 : t.members[Int(rng.next() % UInt64(t.members.count))], into: rng.next() % 2 == 0 ? nil : key)
        case 4, 5: return .pass(dir)
        case 6: return .look(dir)
        case 7: return .lock
        case 8: return .setCols(Int(rng.next() % 3) + 1)
        case 9: return .toggleEmphasis
        default: return .adjustFocusRatio(CGFloat(dir) * 0.05)
        }
    }
}

/// The log texts the e2e scenarios grep for (`scripts/e2e/scenarios.sh`): the executor formats the
/// reducer's lines with app names, and these must come out exactly as today's controller wrote them.
final class LogLineTests: XCTestCase {
    private let names: [CGWindowID: String] = [2: "Notes", 3: "Safari", 4: "Terminal", 5: "Mail"]
    private func text(_ l: LogLine) -> String { l.text { self.names[$0] ?? "?" } }

    func testDrawLines() {
        XCTAssertEqual(text(.draw(drawn: 5, displaced: 4, seat: .R)), "draw: Mail → R (Terminal to the pile)")
        XCTAssertEqual(text(.draw(drawn: 5, displaced: nil, seat: .L)), "draw: Mail → L")
        XCTAssertEqual(text(.drawEmpty(seat: .R)), "draw: nothing to draw into R — the pile is empty")
    }

    func testTradeLines() {
        XCTAssertEqual(text(.trade(.trade, Trade(a: 3, b: 4, from: .C, to: .R), cut: false, cause: .tradeKey(.o))),
                       "trade: Safari C → R, Terminal R → C (spring) ← ⌃⌥⇧O")
        XCTAssertEqual(text(.trade(.trade, Trade(a: 3, b: 2, from: .R, to: .L), cut: true, cause: .tradeKey(.u))),
                       "trade: Safari R → L, Notes L → R (cut) ← ⌃⌥⇧U")
        XCTAssertEqual(text(.trade(.promote, Trade(a: 4, b: 3, from: .R, to: .C), cut: false, cause: .commandKey)),
                       "promote: Terminal R → C, Safari C → R (spring) ← ⌘ key")
        XCTAssertEqual(text(.trade(.promoteUndo, Trade(a: 4, b: 3, from: .C, to: .R), cut: false, cause: .promoteKey)),
                       "promote-undo: Terminal C → R, Safari R → C (spring) ← ⌃⌥↩")
        XCTAssertEqual(text(.tradeNoOp(focus: .C, target: .C)), "trade: no-op (focus C, target C)")
        XCTAssertEqual(text(.promoteNoOp(undo: true)), "promote: no-op (no trade to undo)")
        XCTAssertEqual(text(.promoteNoOp(undo: false)), "promote: no-op (locked seat or monocle)")
    }

    func testPickAndKnobLines() {
        XCTAssertEqual(text(.pick(5, seat: .C, displaced: 3)), "pick: Mail → C (Safari to the pile)")
        XCTAssertEqual(text(.pickNoOp(9)), "pick: no-op (?)")
        XCTAssertEqual(text(.focusRatio(0.55)), "focus ratio: 0.55")
        XCTAssertEqual(text(.monocleWidth(0.6)), "monocle width: 0.60")
        XCTAssertEqual(text(.height(1)), "height: 1.00")
        XCTAssertEqual(text(.gap(inner: 12, outer: 12)), "gap: 12 pad: 12")
    }
}

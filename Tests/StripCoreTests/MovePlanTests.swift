import XCTest
import CoreGraphics
@testable import StripCore

/// Table geometry (seat rects, park frames, park edges), `transitions(from:to:…)` and `MovePlan`:
/// the motion each verb implies, phase by phase (Seats & Pile step 2). Commit 3 asserts the design
/// doc's per-interaction motion budgets on the reducer's plans; these pin the building blocks.
final class MovePlanTests: XCTestCase {
    let stage = Stage(vis: CGRect(x: 0, y: 25, width: 3440, height: 1415))
    private var threeUp: Table { Table(seats: [.L: 2, .C: 3, .R: 4], pile: [5, 1, 6, 7]) }

    private func isOffScreen(_ r: CGRect) -> Bool { !r.intersects(stage.vis) }

    /// The plan for `verb` applied to `table`, with park edges updated the way the reducer will.
    private func plan(_ table: Table, motion: CardMotion = .cut, edges: [CGWindowID: Edge] = [:],
                      _ verb: (inout Table) -> Void) -> (after: Table, plan: MovePlan) {
        var after = table
        verb(&after)
        let edgesAfter = Table.parkEdges(edges, from: table, to: after)
        return (after, MovePlan.build(from: table, to: after, on: stage, edgesBefore: edges,
                                      edgesAfter: edgesAfter, motion: motion))
    }

    // MARK: - Geometry

    func testSeatRectsAreTheSlotGeometryRects() {
        XCTAssertEqual(threeUp.seatRects(on: stage),
                       SlotGeometry.rects(cols: 3, emphasis: .focus, focusSlot: .C, in: stage.vis, config: .default))
    }

    func testAPileCardParksFullyOffItsEdgeSizedLikeTheEndSeat() {
        let rects = threeUp.seatRects(on: stage)
        let right = threeUp.parkFrame(for: 5, edge: .right, on: stage)
        XCTAssertEqual(right.minX, stage.vis.maxX + Stage.parkGap)
        XCTAssertEqual(right.size, rects[.R]!.size)
        XCTAssertEqual(right.midY, stage.vis.midY)
        let left = threeUp.parkFrame(for: 5, edge: .left, on: stage)
        XCTAssertEqual(left.maxX, stage.vis.minX - Stage.parkGap)
        XCTAssertEqual(left.size, rects[.L]!.size)
    }

    func testALearnedConstraintClampsTheParkSize() {
        var s = stage
        s.constraints[5] = SizeConstraint(minWidth: 1500)
        XCTAssertEqual(threeUp.parkFrame(for: 5, edge: .right, on: s).width, 1500)
        XCTAssertEqual(threeUp.parkFrame(for: 5, edge: .left, on: s).maxX, s.vis.minX - Stage.parkGap,
                       "a wider card still parks fully off the left edge")
    }

    func testANeighboringDisplayFlipsTheParkEdge() {
        var s = stage
        s.displays = [CGRect(x: 0, y: 0, width: 3440, height: 1440), CGRect(x: 3440, y: 0, width: 1920, height: 1080)]
        XCTAssertLessThan(threeUp.parkFrame(for: 5, edge: .right, on: s).maxX, s.vis.minX,
                          "a display to the right: park off the left edge instead")
        s.displays = [CGRect(x: 0, y: 0, width: 3440, height: 1440)]
        XCTAssertGreaterThan(threeUp.parkFrame(for: 5, edge: .right, on: s).minX, s.vis.maxX,
                             "the strip display's own frame (Dock, menu bar) is not a neighbor")
    }

    func testParkEdgesFollowTheSeatACardLeft() {
        var t = threeUp
        t.pass(1) // 2 leaves L
        XCTAssertEqual(Table.parkEdges([1: .left], from: threeUp, to: t), [2: .left, 1: .left, 6: .right, 7: .right])
        var c = threeUp
        c.draw(into: .C) // 3 leaves C
        XCTAssertEqual(Table.parkEdges([:], from: threeUp, to: c)[3], .right)
        XCTAssertNil(Table.parkEdges([:], from: threeUp, to: c)[5], "seated cards have no park edge")
    }

    func testATwoUpFocusChangeDoesNotResizeParkedCards() {
        let t = Table(seats: [.L: 1, .R: 2], pile: [3], cols: 2, config: LayoutConfig(focusRatio: 0.7))
        var u = t
        u.look(1)
        XCTAssertNotEqual(t.seatRects(on: stage), u.seatRects(on: stage), "2-up emphasis follows focus")
        XCTAssertEqual(t.parkFrame(for: 3, edge: .right, on: stage), u.parkFrame(for: 3, edge: .right, on: stage))
    }

    func testHiddenWindowsHaveNoTarget() {
        let t = Table(seats: [.C: 3], pile: [5], holes: [.L: 2])
        XCTAssertEqual(Set(t.targets(on: stage, parkEdges: [:]).keys), [3, 5])
    }

    // MARK: - Transitions

    func testContentChangesCutAndPositionChangesSpring() {
        var draw = threeUp
        draw.draw(into: .R)
        XCTAssertEqual(transitions(from: threeUp, to: draw, on: stage),
                       [2: .stay, 3: .stay, 5: .cut, 4: .cut, 1: .stay, 6: .stay, 7: .stay])
        var trade = threeUp
        trade.trade(with: .R)
        let t = transitions(from: threeUp, to: trade, on: stage)
        XCTAssertEqual(t[3], .spring)
        XCTAssertEqual(t[4], .spring)
        var lr = threeUp
        lr.focusSeat = .L
        let before = lr
        lr.trade(with: .R)
        XCTAssertEqual(transitions(from: before, to: lr, on: stage)[2], .cut, "L↔R would spring through C")
    }

    func testSlideMotionSpringsCardsInAndOut() {
        var t = threeUp
        t.pass(1)
        let edges = Table.parkEdges([:], from: threeUp, to: t)
        let kinds = transitions(from: threeUp, to: t, on: stage, edgesAfter: edges, motion: .slide)
        XCTAssertEqual(kinds[2], .spring, "out to the left edge")
        XCTAssertEqual(kinds[5], .spring, "in from the right edge")
        XCTAssertEqual(kinds[3], .spring)
        XCTAssertEqual(kinds[4], .spring)
    }

    func testHiddenWindowsNeverMoveAndARestoreCuts() {
        let hidden = Table(seats: [.C: 3, .R: 4], pile: [5], holes: [.L: 2])
        let shown = Table(seats: [.L: 2, .C: 3, .R: 4], pile: [5])
        XCTAssertEqual(transitions(from: shown, to: hidden, on: stage)[2], .stay, "macOS hid it; Strip doesn't touch it")
        XCTAssertEqual(transitions(from: hidden, to: shown, on: stage)[2], .cut, "the restore takes its seat")
        var mono = hidden
        mono.setCols(1)
        XCTAssertEqual(mono.pile.last, 2)
        XCTAssertEqual(transitions(from: hidden, to: mono, on: stage)[2], .stay, "a hidden window sent to the pile stays put")
    }

    func testAParkedCardThatChangesEdgeSnapsOffscreen() {
        let kinds = transitions(from: threeUp, to: threeUp, on: stage, edgesBefore: [5: .left], edgesAfter: [5: .right])
        XCTAssertEqual(kinds[5], .snapOffscreen)
        XCTAssertEqual(kinds[1], .stay)
    }

    // MARK: - Plans

    func testDrawIntoASatellitePlacesTheCardThenParksTheDisplacedOne() {
        let (_, p) = plan(threeUp) { $0.draw(into: .R) }
        let r = threeUp.seatRects(on: stage)[.R]!
        XCTAssertEqual(p.phases, [
            [MoveStep(id: 5, frame: r, kind: .cut)],
            [MoveStep(id: 4, frame: threeUp.parkFrame(for: 4, edge: .right, on: stage), kind: .cut)],
        ], "parked like the R seat already: no pre-size; the displaced card parks only after")
    }

    func testDrawIntoTheCenterPreSizesTheCardWhileItIsStillParked() {
        let (after, p) = plan(threeUp) { $0.draw(into: .C) }
        let c = after.seatRects(on: stage)[.C]!
        XCTAssertEqual(p.phases.count, 3)
        let presize = p.phases[0]
        XCTAssertEqual(presize.map(\.id), [5])
        XCTAssertEqual(presize[0].frame.size, c.size)
        XCTAssertTrue(isOffScreen(presize[0].frame), "pre-sized off screen")
        XCTAssertEqual(p.phases[1], [MoveStep(id: 5, frame: c, kind: .cut)])
        XCTAssertEqual(p.phases[2].map(\.id), [3])
        XCTAssertEqual(p.steps(.cut).count, 2)
    }

    func testANeighborTradeIsTwoSpringsInOnePhase() {
        let (_, p) = plan(threeUp) { $0.trade(with: .R) }
        XCTAssertEqual(p.phases.count, 1)
        XCTAssertEqual(p.steps(.spring).map(\.id), [3, 4])
    }

    func testALeftRightTradeIsTwoCuts() {
        var t = threeUp
        t.focusSeat = .L
        let (_, p) = plan(t) { $0.trade(with: .R) }
        XCTAssertEqual(p.phases.count, 1)
        XCTAssertEqual(p.steps(.cut).map(\.id), [2, 4])
    }

    func testPassIsFourSpringsOneSeatEach() {
        let (_, p) = plan(threeUp, motion: .slide) { $0.pass(1) }
        XCTAssertEqual(p.phases.count, 1, "the incoming card already rests off the right edge")
        XCTAssertEqual(p.steps(.spring).map(\.id), [2, 3, 4, 5])
        let was = threeUp.targets(on: stage, parkEdges: [:])
        for s in p.steps {
            XCTAssertFalse(MotionPolicy.sweepsAcross(from: was[s.id]!, to: s.frame, in: stage.vis), "window \(s.id) sweeps")
        }
        XCTAssertLessThan(p.steps.first { $0.id == 2 }!.frame.maxX, stage.vis.minX, "2 leaves off the left edge")
    }

    func testPassFromACardParkedOnTheFarEdgeSnapsItAcrossFirst() {
        let (after, p) = plan(threeUp, motion: .slide, edges: [5: .left]) { $0.pass(1) }
        XCTAssertEqual(p.phases.count, 2)
        XCTAssertEqual(p.phases[0].map(\.kind), [.snap])
        XCTAssertEqual(p.phases[0][0].id, 5)
        XCTAssertGreaterThan(p.phases[0][0].frame.minX, stage.vis.maxX, "moved to the right park, invisibly")
        XCTAssertEqual(p.phases[1].first { $0.id == 5 }, MoveStep(id: 5, frame: after.seatRects(on: stage)[.R]!, kind: .spring))
    }

    func testASpringThatWouldSweepTheDisplayBecomesACut() {
        var after = threeUp
        after.draw(into: .R)
        let p = MovePlan.build(from: threeUp, to: after, on: stage, edgesAfter: [4: .left], motion: .slide)
        XCTAssertEqual(p.steps.first { $0.id == 4 }?.kind, .cut, "R → left park would cross C and L")
        XCTAssertEqual(p.phases.last?.map(\.id), [4], "and it parks last")
    }

    func testLookingAndLockingMoveNothingIn3Up() {
        XCTAssertTrue(plan(threeUp) { $0.look(1) }.plan.isEmpty)
        XCTAssertTrue(plan(threeUp) { $0.toggleLock() }.plan.isEmpty)
        XCTAssertTrue(plan(threeUp) { _ = $0.focusFollow(2) }.plan.isEmpty)
    }

    func testGoingToMonocleCutsTheSatellitesAndResizesTheCenterInPlace() {
        let (_, p) = plan(threeUp) { $0.setCols(1) }
        XCTAssertEqual(p.steps(.cut).map(\.id), [2, 4], "up to 2 cuts")
        XCTAssertEqual(p.steps(.spring).map(\.id), [3], "C resized in place")
        XCTAssertTrue(p.steps(.snap).allSatisfy { isOffScreen($0.frame) }, "parked cards resize unseen")
    }

    func testANewFocusedWindowTakesTheCenterAndTheOldOneParks() {
        let from = Table(seats: [.L: 2, .C: 3, .R: 4], pile: [5])
        let to = Table(seats: [.L: 2, .C: 9, .R: 4], pile: [3, 5])
        let opened = CGRect(x: 1000, y: 200, width: 900, height: 700)
        let p = MovePlan.build(from: from, to: to, on: stage, edgesAfter: Table.parkEdges([:], from: from, to: to),
                               current: [9: opened])
        XCTAssertEqual(p.phases.map { $0.map(\.id) }, [[9], [3]], "1 visible + 1 parked, in that order")
        XCTAssertTrue(p.steps.allSatisfy { $0.kind == .cut })
    }

    func testPlansAreDeterministic() {
        let a = plan(threeUp, motion: .slide) { $0.pass(1) }.plan
        let b = plan(threeUp, motion: .slide) { $0.pass(1) }.plan
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.phases[0].map(\.id), a.phases[0].map(\.id).sorted())
    }

    // MARK: - Plan properties over a random walk

    /// For every verb on random tables, under both motions: no spring sweeps across the display, no
    /// window gets more than two steps (and then prepare before show), every parked card's frame is
    /// off screen, hidden windows never move, and a cut that takes a window off screen always runs
    /// after the cuts that put windows on screen.
    func testEveryPlanKeepsTheMotionRules() {
        var rng = SplitMix64(seed: 0xC07)
        for _ in 0..<300 {
            var t = Table(seats: [.L: 1, .C: 2, .R: 3], pile: [4, 5, 6], holes: rng.next() % 3 == 0 ? [.L: 7] : [:])
            t.setCols(Int.random(in: 1...3, using: &rng))
            var edges: [CGWindowID: Edge] = Dictionary(uniqueKeysWithValues: t.pile.map { ($0, Bool.random(using: &rng) ? .left : .right) })
            for _ in 0..<12 {
                let before = t
                switch rng.next() % 7 {
                case 0: t.draw(into: t.slots.randomElement(using: &rng)!)
                case 1: t.trade(with: t.slots.randomElement(using: &rng)!)
                case 2: t.promote()
                case 3: t.pass(Bool.random(using: &rng) ? 1 : -1)
                case 4: t.setCols(Int.random(in: 1...3, using: &rng))
                case 5: if let id = t.members.randomElement(using: &rng) { t.pick(id, into: t.slots.randomElement(using: &rng)!) }
                default: t.emphasis = t.emphasis == .focus ? .equal : .focus
                }
                let motion: CardMotion = Bool.random(using: &rng) ? .slide : .cut
                let edgesAfter = Table.parkEdges(edges, from: before, to: t)
                let p = MovePlan.build(from: before, to: t, on: stage, edgesBefore: edges, edgesAfter: edgesAfter, motion: motion)
                let was = before.targets(on: stage, parkEdges: edges)
                let hidden = Set(t.holes.values)

                var count: [CGWindowID: Int] = [:]
                var phaseOf: [CGWindowID: [Int]] = [:]
                for (i, phase) in p.phases.enumerated() {
                    for s in phase {
                        count[s.id, default: 0] += 1
                        phaseOf[s.id, default: []].append(i)
                    }
                }
                XCTAssertTrue(count.values.allSatisfy { $0 <= 2 })
                XCTAssertTrue(phaseOf.values.allSatisfy { $0 == $0.sorted() && Set($0).count == $0.count })
                XCTAssertTrue(p.ids.isDisjoint(with: hidden), "a hidden window moved")
                var cur = was
                for phase in p.phases {
                    for s in phase where s.kind == .spring {
                        if let from = cur[s.id] {
                            XCTAssertFalse(MotionPolicy.sweepsAcross(from: from, to: s.frame, in: stage.vis),
                                           "window \(s.id) springs across the display")
                        }
                    }
                    for s in phase { cur[s.id] = s.frame }
                }
                for id in t.pile where cur[id] != nil {
                    XCTAssertTrue(isOffScreen(cur[id]!), "parked window \(id) ends on screen")
                }
                let lastShow = p.phases.lastIndex { $0.contains { $0.kind == .cut && !isOffScreen($0.frame) } } ?? -1
                let firstClear = p.phases.firstIndex { $0.contains { $0.kind == .cut && isOffScreen($0.frame) } } ?? Int.max
                XCTAssertLessThan(lastShow, firstClear, "a window parked before its replacement was placed")
                edges = edgesAfter
            }
        }
    }
}

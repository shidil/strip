import XCTest
import CoreGraphics
@testable import StripCore

/// The reducer's window events (Seats & Pile step 2, commit 4): enumeration diffs (new, close,
/// hide / minimize, restore, startup adoption), native tabs, display changes, user drags, size
/// clamps and lost windows, each with the design doc's motion budget asserted on the plan.
final class ReducerWorldTests: XCTestCase {
    let stage = Stage(vis: CGRect(x: 0, y: 25, width: 3440, height: 1415))
    let opened = CGRect(x: 900, y: 200, width: 1200, height: 900)

    /// 3-up: L=2 C=3 R=4; pile 5, 1, 6, 7; every window where the reducer put it; 3 has focus.
    private var threeUp: CoreState {
        var s = CoreState(table: Table(seats: [.L: 2, .C: 3, .R: 4], pile: [5, 1, 6, 7]), stage: stage)
        s.lastTargets = s.table.targets(on: stage, parkEdges: s.parkEdges)
        for (id, f) in s.lastTargets { s.windows[id] = WindowInfo(id: id, frame: f) }
        s.handedFocus = 3
        s.recent = [3]
        return s
    }

    /// What an enumeration of `s` reports: every window, at the frame the reducer last commanded,
    /// with its known visibility; `change` edits the list.
    private func snapshot(_ s: CoreState, _ change: (inout [WindowInfo]) -> Void = { _ in }) -> [WindowInfo] {
        var list = s.table.members.map { id in
            s.windows[id] ?? WindowInfo(id: id, frame: s.lastTargets[id] ?? .zero)
        }
        change(&list)
        return list
    }

    private func enumerate(_ s: CoreState, focused: CGWindowID?, at now: CFTimeInterval = 0,
                           _ change: (inout [WindowInfo]) -> Void = { _ in }) -> Reduction {
        Reducer.reduce(s, .windowsEnumerated(snapshot(s, change), focused: focused), now: now)
    }

    private func ids(_ p: MovePlan, _ kind: MoveKind) -> [CGWindowID] { p.steps(kind).map(\.id).sorted() }
    /// The moves the user sees: everything but the invisible snaps (a card pre-sized while parked).
    private func visible(_ p: MovePlan) -> [MoveStep] { p.steps.filter { $0.kind != .snap } }
    private func logs(_ r: Reduction) -> [LogLine] {
        r.effects.compactMap { if case let .log(l) = $0 { return l } else { return nil } }
    }
    private func onScreen(_ r: CGRect) -> Bool { r.intersects(stage.vis) }

    // MARK: - Nothing changed

    func testAnUnchangedEnumerationDoesNothing() {
        let r = enumerate(threeUp, focused: 3)
        XCTAssertEqual(r.plan, .none)
        XCTAssertEqual(r.effects, [])
        XCTAssertEqual(r.state, threeUp)
    }

    // MARK: - New window: "1 visible + 1 parked"

    func testAFocusedNewWindowTakesTheCenterAndTheOldCenterParks() {
        let r = enumerate(threeUp, focused: 9) { $0.insert(WindowInfo(id: 9, frame: self.opened), at: 0) }
        XCTAssertEqual(r.state.table.seats, [.L: 2, .C: 9, .R: 4])
        XCTAssertEqual(r.plan.phases.map { $0.map(\.id) }, [[9], [3]], "9 placed, then 3 parked")
        XCTAssertTrue(r.plan.steps.allSatisfy { $0.kind == .cut })
        XCTAssertEqual(logs(r), [.added(9, seat: .C)])
        XCTAssertEqual(r.state.handedFocus, 9, "macOS already focused it")
        XCTAssertNil(r.state.pending.focusHandOff, "so nothing re-activates it")
    }

    func testABackgroundNewWindowJoinsTheTopOfThePile() {
        let r = enumerate(threeUp, focused: 3) { $0.append(WindowInfo(id: 9, frame: self.opened)) }
        XCTAssertEqual(r.state.table.pile.first, 9)
        XCTAssertEqual(r.plan.steps.map(\.id), [9], "1 parked")
        XCTAssertFalse(onScreen(r.plan.steps[0].frame))
        XCTAssertEqual(r.state.table.seats, threeUp.table.seats)
    }

    func testTheAppendPlacementTucksEveryNewWindowUnderThePile() {
        var s = threeUp
        s.table.config.newWindowPlacement = .append
        let r = enumerate(s, focused: 9) { $0.insert(WindowInfo(id: 9, frame: self.opened), at: 0) }
        XCTAssertEqual(r.state.table.pile.last, 9)
        XCTAssertEqual(r.state.table.seats[.C], 3, "never steals the center")
    }

    func testABatchPutsTheFocusedOneInTheCenterAndTheRestFrontmostFirstOnThePile() {
        let r = enumerate(threeUp, focused: 10) {
            $0.insert(contentsOf: [WindowInfo(id: 9, frame: self.opened), WindowInfo(id: 10, frame: self.opened),
                                   WindowInfo(id: 11, frame: self.opened)], at: 0)
        }
        XCTAssertEqual(r.state.table.seats[.C], 10)
        XCTAssertEqual(Array(r.state.table.pile.prefix(3)), [3, 9, 11])
    }

    func testSmallOrOffStripWindowsFloatButOrphansAreReclaimed() {
        var s = stage
        s.displays = [CGRect(x: 0, y: 0, width: 3440, height: 1440), CGRect(x: 3440, y: 0, width: 1920, height: 1080)]
        var state = threeUp
        state.stage = s
        let r = enumerate(state, focused: 3) {
            $0 += [WindowInfo(id: 9, frame: CGRect(x: 100, y: 100, width: 400, height: 300)),     // a palette
                   WindowInfo(id: 10, frame: CGRect(x: 3600, y: 100, width: 1200, height: 900)),  // other display
                   WindowInfo(id: 11, frame: CGRect(x: 9000, y: 100, width: 1200, height: 900)),  // on no display
                   WindowInfo(id: 12, frame: self.opened, visibility: .minimized)]                // not shown
        }
        XCTAssertFalse(r.state.table.contains(9), "small windows float")
        XCTAssertFalse(r.state.table.contains(10), "another display's window isn't the strip's")
        XCTAssertTrue(r.state.table.contains(11), "an orphan parked by a dead Strip is reclaimed")
        XCTAssertFalse(r.state.table.contains(12))
        let grown = enumerate(r.state, focused: 3) {
            $0.append(WindowInfo(id: 9, frame: CGRect(x: 100, y: 100, width: 1200, height: 900)))
        }
        XCTAssertTrue(grown.state.table.contains(9), "admitted once it's big enough")
    }

    // MARK: - Close: "1 or 0"

    func testClosingTheCenterRefillsItWithTheWindowMacOSFocused() {
        let r = enumerate(threeUp, focused: 6) { $0.removeAll { $0.id == 3 } }
        XCTAssertEqual(r.state.table.seats[.C], 6)
        XCTAssertEqual(visible(r.plan), [MoveStep(id: 6, frame: r.state.table.seatRects(on: stage)[.C]!, kind: .cut)],
                       "one cut (after pre-sizing 6 while it's still parked)")
        XCTAssertEqual(logs(r), [.closed(3, refill: 6)])
        XCTAssertNil(r.state.pending.focusHandOff, "6 already has focus")
    }

    func testWhenMacOSFocusesASatelliteTheRefillComesFromThePileAndFocusFollows() {
        let r = enumerate(threeUp, focused: 2) { $0.removeAll { $0.id == 3 } }
        XCTAssertEqual(r.state.table.seats[.C], 5, "pile[0]")
        XCTAssertEqual(r.state.table.focusSeat, .L, "focus follows macOS to L, without moving anything")
        XCTAssertNil(r.state.pending.focusHandOff, "nothing to activate")
        XCTAssertEqual(visible(r.plan).map(\.id), [5])
    }

    func testClosingAPileCardMovesNothing() {
        let r = enumerate(threeUp, focused: 3) { $0.removeAll { $0.id == 6 } }
        XCTAssertTrue(r.plan.isEmpty)
        XCTAssertEqual(r.effects, [.log(.closed(6, refill: nil)), .render])
        XCTAssertNil(r.state.lastTargets[6])
        XCTAssertNil(r.state.windows[6])
    }

    func testClosingTheCenterWithAnEmptyPilePromotesTheMostRecentSatellite() {
        var s = CoreState(table: Table(seats: [.L: 2, .C: 3, .R: 4]), stage: stage)
        s.recent = [4, 2]
        s.handedFocus = 3
        let r = enumerate(s, focused: nil) { $0.removeAll { $0.id == 3 } }
        XCTAssertEqual(r.state.table.seats, [.L: 2, .C: 4])
        XCTAssertEqual(r.plan.steps.map(\.id), [4], "1 move")
        XCTAssertEqual(r.plan.steps[0].kind, .spring, "R → C is one seat")
    }

    func testAfterEverythingClosesANewWindowIsAdopted() {
        let gone = enumerate(threeUp, focused: nil) { $0.removeAll() }
        XCTAssertTrue(gone.state.table.members.isEmpty)
        XCTAssertEqual(gone.state.table.invariantViolations(), [])
        let back = enumerate(gone.state, focused: 9) { $0 = [WindowInfo(id: 9, frame: self.opened)] }
        XCTAssertEqual(back.state.table.seats, [.C: 9])
        XCTAssertEqual(logs(back), [.adopted(count: 1)])
    }

    // MARK: - Startup adoption

    func testStartupAdoptsBySeatRectThenFrontToBack() {
        let s = CoreState(stage: stage)
        let rects = Table().seatRects(on: stage)
        let r = Reducer.reduce(s, .windowsEnumerated([
            WindowInfo(id: 1, frame: opened), WindowInfo(id: 2, frame: rects[.R]!), WindowInfo(id: 3, frame: opened),
            WindowInfo(id: 4, frame: opened),
        ], focused: 3), now: 0)
        XCTAssertEqual(r.state.table.seats, [.L: 1, .C: 3, .R: 2])
        XCTAssertEqual(r.state.table.pile, [4])
        XCTAssertFalse(r.plan.ids.contains(2), "already in R: no write")
        XCTAssertEqual(r.state.table.invariantViolations(), [])
    }

    // MARK: - Hide / minimize: "0"; restore into C: "1 visible"

    func testAMinimizedSatelliteLeavesAHoleAndNothingMoves() {
        let r = enumerate(threeUp, focused: 3) { list in
            list = list.map { var w = $0; if w.id == 4 { w.visibility = .minimized }; return w }
        }
        XCTAssertEqual(r.state.table.holes, [.R: 4])
        XCTAssertTrue(r.plan.isEmpty)
        let back = enumerate(r.state, focused: 4) { list in
            list = list.map { var w = $0; if w.id == 4 { w.visibility = .shown }; return w }
        }
        XCTAssertEqual(back.state.table.seats[.R], 4)
        XCTAssertTrue(back.plan.isEmpty, "it restores into its own seat's rect")
        XCTAssertEqual(logs(back), [.restored(4, seat: .R)])
    }

    func testAHiddenCenterIsRefilledAndItsRestoreTakesTheCenterBack() {
        let hide = enumerate(threeUp, focused: nil) { list in
            list = list.map { var w = $0; if w.id == 3 { w.visibility = .hidden }; return w }
        }
        XCTAssertEqual(hide.state.table.seats[.C], 5)
        XCTAssertEqual(hide.state.table.holes, [.C: 3])
        XCTAssertEqual(visible(hide.plan).map(\.id), [5], "the refill is one cut; the hidden window isn't touched")

        let back = enumerate(hide.state, focused: 3) { list in
            list = list.map { var w = $0; if w.id == 3 { w.visibility = .shown }; return w }
        }
        XCTAssertEqual(back.state.table.seats[.C], 3)
        XCTAssertEqual(back.state.table.pile.first, 5)
        XCTAssertEqual(back.plan.steps.map(\.id), [5], "1 visible: the refill parks; 3 is already in C")
        XCTAssertFalse(onScreen(back.plan.steps[0].frame))
    }

    func testAMinimizedPileCardIsNeverWrittenNorDrawn() {
        let hide = enumerate(threeUp, focused: 3) { list in
            list = list.map { var w = $0; if w.id == 5 { w.visibility = .minimized }; return w }
        }
        XCTAssertEqual(hide.state.table.hidden, [5])
        let mono = Reducer.reduce(hide.state, .chord(.setCols(1), repeated: false), now: 1)
        XCTAssertFalse(mono.plan.ids.contains(5), "a minimized window is never written")
        let draw = Reducer.reduce(hide.state, .chord(.draw(.o), repeated: false), now: 1)
        XCTAssertEqual(draw.state.table.seats[.R], 1)
    }

    func testARestoredPileCardIsSummonedIntoTheCenter() {
        let hide = enumerate(threeUp, focused: 3) { list in
            list = list.map { var w = $0; if w.id == 6 { w.visibility = .minimized }; return w }
        }
        let back = enumerate(hide.state, focused: 6) { list in
            list = list.map { var w = $0; if w.id == 6 { w.visibility = .shown }; return w }
        }
        XCTAssertEqual(back.state.table.seats[.C], 6)
        XCTAssertEqual(ids(back.plan, .cut), [3, 6])
    }

    // MARK: - Native tabs

    func testATabSwitchKeepsThePaneInPlace() {
        let same = Reducer.reduce(threeUp, .tabReplaced(old: 3, new: WindowInfo(id: 30, frame: threeUp.lastTargets[3]!)), now: 0)
        XCTAssertEqual(same.state.table.seats[.C], 30)
        XCTAssertTrue(same.plan.isEmpty, "the new tab window is already where the old one was")
        XCTAssertEqual(same.state.handedFocus, 30)
        XCTAssertNil(same.state.lastTargets[3])
        XCTAssertEqual(logs(same), [.tabReplaced(old: 3, new: 30)])

        let off = Reducer.reduce(threeUp, .tabReplaced(old: 3, new: WindowInfo(id: 30, frame: opened)), now: 0)
        XCTAssertEqual(off.plan.steps, [MoveStep(id: 30, frame: threeUp.lastTargets[3]!, kind: .spring)])
        XCTAssertEqual(Reducer.reduce(threeUp, .tabReplaced(old: 99, new: WindowInfo(id: 30, frame: opened)), now: 0).effects, [])
    }

    // MARK: - Displays

    func testADisplayChangeReLaysEveryWindowOut() {
        let r = Reducer.reduce(threeUp, .displayChanged(vis: CGRect(x: 0, y: 25, width: 2560, height: 1415), displays: []), now: 0)
        XCTAssertEqual(ids(r.plan, .spring), [2, 3, 4], "seats glide to the new rects")
        XCTAssertEqual(ids(r.plan, .snap), [1, 5, 6, 7], "parked cards follow, unseen")
        XCTAssertEqual(Reducer.reduce(threeUp, .displayChanged(vis: stage.vis, displays: []), now: 0).effects, [])
    }

    // MARK: - User drags

    func testADraggedWindowSnapsBackFromWhereItWasDropped() {
        let dropped = CGRect(x: 2000, y: 300, width: 1000, height: 900)
        let r = Reducer.reduce(threeUp, .dragEnded(4, wasResize: false, frame: dropped), now: 0)
        XCTAssertEqual(r.plan.steps, [MoveStep(id: 4, frame: threeUp.lastTargets[4]!, kind: .spring)])
        XCTAssertEqual(r.effects, [.log(.snappedBack(4)), .reseed(4, at: dropped), .render])
        var stepping = threeUp
        stepping.windows[4]?.steps = true
        let cut = Reducer.reduce(stepping, .dragEnded(4, wasResize: false, frame: dropped), now: 0)
        XCTAssertEqual(cut.plan.steps.map(\.kind), [.cut], "a terminal moves back in one write")
    }

    func testResizingTheDominantWindowIsKeptAndTheRowReProportions() {
        var wide = threeUp.lastTargets[3]!
        wide = wide.insetBy(dx: -200, dy: 0)
        let r = Reducer.reduce(threeUp, .dragEnded(3, wasResize: true, frame: wide), now: 0)
        XCTAssertGreaterThan(r.state.table.config.focusRatio, threeUp.table.config.focusRatio)
        XCTAssertTrue(r.effects.contains(.persist))
        XCTAssertEqual(logs(r), [.resizeKept(focusRatio: r.state.table.config.focusRatio,
                                             monocleWidth: r.state.table.config.monocleWidthFraction,
                                             height: r.state.table.config.heightFraction)])
        XCTAssertEqual(ids(r.plan, .spring), [2, 4], "the neighbors make room; C stays where you left it")
    }

    func testResizingASatelliteSnapsItBack() {
        let r = Reducer.reduce(threeUp, .dragEnded(4, wasResize: true, frame: threeUp.lastTargets[4]!.insetBy(dx: -100, dy: 0)), now: 0)
        XCTAssertEqual(logs(r), [.snappedBack(4)])
        XCTAssertEqual(r.state.table.config, threeUp.table.config)
        XCTAssertEqual(ids(r.plan, .spring), [4])
    }

    // MARK: - Size clamps

    func testAClampThatTeachesAMinimumReLaysTheRowOut() {
        let requested = threeUp.lastTargets[4]!
        var actual = requested
        actual.size.width += 200
        let r = Reducer.reduce(threeUp, .frameClamped(4, requested: requested, actual: actual), now: 0)
        XCTAssertEqual(r.state.stage.constraints[4]?.minWidth, actual.width)
        XCTAssertEqual(logs(r).first, .constraintLearned(4, r.state.stage.constraints[4]!))
        XCTAssertEqual(r.state.table.seatRects(on: r.state.stage)[.R]!.width, actual.width, accuracy: 0.5)
        XCTAssertTrue(r.plan.ids.isSuperset(of: [2, 3]), "the others make room")
        XCTAssertTrue(r.plan.steps.filter { $0.id == 4 }.allSatisfy { $0.frame.width >= actual.width - 0.5 },
                      "R may shift, but never below the floor it just taught")
    }

    func testAClampThatTeachesNothingOrIsStaleIsIgnored() {
        let requested = threeUp.lastTargets[4]!
        var nudged = requested
        nudged.size.width += 4
        XCTAssertEqual(Reducer.reduce(threeUp, .frameClamped(4, requested: requested, actual: nudged), now: 0).effects, [],
                       "a stepping app's few points teach nothing")
        var wide = requested
        wide.size.width += 200
        let stale = requested.offsetBy(dx: 500, dy: 0)
        XCTAssertEqual(Reducer.reduce(threeUp, .frameClamped(4, requested: stale, actual: wide), now: 0).effects, [],
                       "the reducer has since asked for something else")
    }

    // MARK: - Lost windows

    func testAWindowWhoseWritesFailIsDroppedLikeAClose() {
        let r = Reducer.reduce(threeUp, .writeFailed(4), now: 0)
        XCTAssertEqual(logs(r), [.axDrop(4), .closed(4, refill: 5)])
        XCTAssertEqual(r.state.table.seats[.R], 5)
        XCTAssertEqual(r.plan.steps.map(\.id), [5])
        XCTAssertEqual(Reducer.reduce(threeUp, .writeFailed(99), now: 0).effects, [])
    }

    // MARK: - Random run

    /// Enumerations that open, close, hide and restore windows at random, mixed with commands,
    /// keep the table sound, never write a hidden window, and keep the bookkeeping to managed
    /// windows.
    func testARandomRunOfWindowsAndCommandsKeepsTheStateSound() {
        var rng = SplitMix64(seed: 0xBEEF)
        for _ in 0..<40 {
            var s = threeUp
            var next: CGWindowID = 20
            var t: CFTimeInterval = 0
            for _ in 0..<50 {
                t += 0.1
                let r: Reduction
                switch rng.next() % 6 {
                case 0:
                    let id = next; next += 1
                    r = enumerate(s, focused: rng.next() % 2 == 0 ? id : s.handedFocus, at: t) {
                        $0.insert(WindowInfo(id: id, frame: self.opened), at: 0)
                    }
                case 1:
                    let gone = s.table.members.randomElement(using: &rng)
                    r = enumerate(s, focused: s.table.pile.randomElement(using: &rng), at: t) { $0.removeAll { $0.id == gone } }
                case 2:
                    let id = s.table.members.randomElement(using: &rng)
                    let vis: Visibility = [.shown, .minimized, .hidden][Int(rng.next() % 3)]
                    r = enumerate(s, focused: s.handedFocus, at: t) { list in
                        list = list.map { var w = $0; if w.id == id { w.visibility = vis }; return w }
                    }
                case 3:
                    r = Reducer.reduce(s, .chord([.draw(.i), .pass(1), .setCols(Int(rng.next() % 3) + 1), .trade(.o), .look(1)][Int(rng.next() % 5)], repeated: false), now: t)
                case 4:
                    r = Reducer.reduce(s, .tick, now: t)
                default:
                    if let id = s.table.seated.randomElement(using: &rng) {
                        r = Reducer.reduce(s, .dragEnded(id, wasResize: rng.next() % 2 == 0, frame: opened), now: t)
                    } else {
                        r = Reducer.reduce(s, .tick, now: t)
                    }
                }
                let hidden = Set(r.state.windows.filter { $0.value.visibility != .shown }.keys)
                XCTAssertTrue(r.plan.ids.isDisjoint(with: hidden), "a hidden window was written")
                s = r.state
                XCTAssertEqual(s.table.invariantViolations(), [])
                let members = Set(s.table.members)
                XCTAssertTrue(Set(s.windows.keys).isSubset(of: members))
                XCTAssertTrue(Set(s.lastTargets.keys).isSubset(of: members))
                XCTAssertTrue(Set(s.recent).isSubset(of: members))
                XCTAssertEqual(Set(s.parkEdges.keys), Set(s.table.pile))
            }
        }
    }
}

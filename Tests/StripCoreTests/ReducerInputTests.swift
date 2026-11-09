import XCTest
import CoreGraphics
@testable import StripCore

/// Drives the reducer like the executor does: events at given times, and a `.tick` whenever the one
/// timer the reducer's `wake` effects set comes due. Keeps every reduction for the assertions.
struct Session {
    var state: CoreState
    /// The executor's one timer: the last `wake` the reducer emitted.
    var timer: CFTimeInterval?
    var clock: CFTimeInterval = 0
    var log: [(at: CFTimeInterval, event: CoreEvent, reduction: Reduction)] = []

    init(_ state: CoreState) { self.state = state }

    /// Run every tick due by `t`, then `event` at `t`.
    @discardableResult
    mutating func send(_ event: CoreEvent, at t: CFTimeInterval) -> Reduction {
        advance(to: t)
        return apply(event, at: t)
    }

    /// Run every tick due by `t`.
    mutating func advance(to t: CFTimeInterval) {
        var guardrail = 0
        while let at = timer, at <= t {
            timer = nil
            apply(.tick, at: max(at, clock))
            guardrail += 1
            precondition(guardrail < 1000, "ticks never settle")
        }
        clock = max(clock, t)
    }

    @discardableResult
    private mutating func apply(_ event: CoreEvent, at t: CFTimeInterval) -> Reduction {
        let r = Reducer.reduce(state, event, now: t)
        for case let .wake(at) in r.effects { timer = at }
        state = r.state
        clock = t
        log.append((t, event, r))
        return r
    }

    /// Reductions after time `t` (exclusive), or all.
    func since(_ t: CFTimeInterval = -.infinity) -> [Reduction] {
        log.filter { $0.at > t }.map(\.reduction)
    }
}

/// Input and focus timing (Seats & Pile step 2, commit 5): attribution, Strip's own activations,
/// focus following, hand-off cancels and re-syncs, the ⌘Tab promote settle, committed clicks, the
/// parked summon and pill, and the re-scan debounce, all as deadlines in `CoreState.pending`. The
/// motion budgets are the design doc's (*Interactions*, "Windows moved").
final class ReducerInputTests: XCTestCase {
    let stage = Stage(vis: CGRect(x: 0, y: 25, width: 3440, height: 1415))
    let interval: CFTimeInterval = 0.5
    let point = CGPoint(x: 3000, y: 600)

    /// 3-up: L=2 C=3 R=4; pile 5, 1, 6, 7; every window where the reducer put it, window n in app
    /// pid 10n; 3 has focus. Click-to-center as given.
    private func threeUp(clickToCenter: Bool = true) -> CoreState {
        var s = CoreState(table: Table(seats: [.L: 2, .C: 3, .R: 4], pile: [5, 1, 6, 7]), stage: stage)
        s.lastTargets = s.table.targets(on: stage, parkEdges: s.parkEdges)
        for (id, f) in s.lastTargets { s.windows[id] = WindowInfo(id: id, pid: pid(id), frame: f) }
        s.handedFocus = 3
        s.recent = [3]
        s.clickToCenter = clickToCenter
        return s
    }

    private func pid(_ id: CGWindowID) -> Int32 { Int32(id) * 10 }
    private func focus(_ id: CGWindowID) -> CoreEvent { .focusChanged(id, pid: pid(id)) }
    private func down(_ p: CGPoint? = nil) -> CoreEvent { .userInput(.mouseDown(at: p ?? point)) }
    private func up(_ p: CGPoint? = nil, count: Int = 1, hit: CGWindowID?) -> CoreEvent {
        .userInput(.mouseUp(at: p ?? point, clickCount: count, hit: hit, doubleClickInterval: interval))
    }
    private let cmd = CoreEvent.userInput(.commandKey)

    private func plans(_ rs: [Reduction]) -> [MoveStep] { rs.flatMap(\.plan.steps) }
    /// The moves the user sees: everything but the invisible snaps (a card pre-sized while parked).
    private func visible(_ rs: [Reduction]) -> [MoveStep] { plans(rs).filter { $0.kind != .snap } }
    private func effects(_ rs: [Reduction]) -> [SideEffect] { rs.flatMap(\.effects) }
    private func logs(_ rs: [Reduction]) -> [LogLine] {
        effects(rs).compactMap { if case let .log(l) = $0 { return l } else { return nil } }
    }
    private func focuses(_ rs: [Reduction]) -> [CGWindowID] {
        effects(rs).compactMap { if case let .focus(id) = $0 { return id } else { return nil } }
    }
    private func count(_ rs: [Reduction], _ e: SideEffect) -> Int { effects(rs).filter { $0 == e }.count }
    private func promotes(_ rs: [Reduction]) -> [LogLine] {
        logs(rs).filter { if case .trade(.promote, _, _, _) = $0 { return true } else { return false } }
    }

    // MARK: - Focus into a seat: "0"

    func testFocusIntoASatelliteFollowsWithNoMotion() {
        var s = Session(threeUp(clickToCenter: false))
        let r = s.send(focus(4), at: 1)
        XCTAssertEqual(r.plan, .none)
        XCTAssertEqual(s.state.table.focusSeat, .R)
        XCTAssertEqual(s.state.handedFocus, 4)
        XCTAssertEqual(s.state.recent.first, 4)
        XCTAssertEqual(logs([r]), [.focusFollow(4, seat: .R)])
        s.advance(to: 5)
        XCTAssertEqual(focuses(s.since()), [], "macOS already focused it")
        XCTAssertEqual(plans(s.since()), [])
    }

    func testFocusIntoTheFocusedWindowChangesNothing() {
        let s = threeUp()
        let r = Reducer.reduce(s, focus(3), now: 1)
        XCTAssertEqual(r.plan, .none)
        XCTAssertEqual(r.effects, [])
    }

    // MARK: - Unknown windows and the re-scan debounce

    func testMembershipHintsAreDebouncedIntoOneEnumeration() {
        var s = Session(threeUp())
        s.send(.membershipHint(pid: 90), at: 1)
        s.send(.membershipHint(pid: 30), at: 1.05)
        s.advance(to: 1.12)
        XCTAssertEqual(count(s.since(), .enumerate), 0, "trailing: the second hint restarted the wait")
        s.advance(to: 1.125)
        XCTAssertEqual(count(s.since(), .enumerate), 1)
        s.advance(to: 3)
        XCTAssertEqual(count(s.since(), .enumerate), 1)
    }

    func testFocusIntoAnUnknownUnreadableOrHiddenWindowAsksForAReScan() {
        var s = Session(threeUp())
        s.send(.focusChanged(99, pid: 990), at: 1)
        s.advance(to: 1.075)
        XCTAssertEqual(count(s.since(), .enumerate), 1)
        XCTAssertEqual(s.state.handedFocus, 3, "unknown: nothing followed")

        s.send(.focusChanged(nil, pid: 30), at: 2)
        s.advance(to: 2.075)
        XCTAssertEqual(count(s.since(1.5), .enumerate), 1)

        var hidden = threeUp()
        hidden.table.pile.removeAll { $0 == 7 }
        hidden.table.hidden = [7]
        s = Session(hidden)
        s.send(focus(7), at: 1)
        s.advance(to: 1.075)
        XCTAssertEqual(count(s.since(), .enumerate), 1, "a window we think is minimized is back")
    }

    // MARK: - Strip's own activations

    func testAFocusChangeInsideTheGraceAfterStripsOwnActivationIsStripsOwn() {
        var s = Session(threeUp())
        s.send(.chord(.look(1), repeated: false), at: 0) // hand-off to 4 at 0.17
        s.advance(to: 0.17)
        XCTAssertEqual(focuses(s.since()), [4])
        s.send(.focusChanged(nil, pid: pid(4)), at: 0.3)  // its app's own notification burst
        s.advance(to: 1)
        XCTAssertEqual(count(s.since(), .enumerate), 0, "no re-scan for Strip's own activation")

        s.send(.focusChanged(nil, pid: pid(4)), at: 1.2)  // well after the grace: a real change
        s.advance(to: 2)
        XCTAssertEqual(count(s.since(1), .enumerate), 1)
    }

    func testUserInputAfterStripsActivationEndsTheGrace() {
        var s = Session(threeUp(clickToCenter: false))
        s.send(.chord(.look(1), repeated: false), at: 0)
        s.advance(to: 0.17)
        s.send(down(), at: 0.2)
        let r = s.send(.focusChanged(4, pid: pid(4)), at: 0.25)
        XCTAssertEqual(s.state.input.arrival, Stamp(4, at: 0.25), "the user's own click, followed")
        XCTAssertEqual(r.plan, .none)
    }

    // MARK: - Hand-off cancels and the re-sync

    func testAClickOrCommandKeyCancelsAPendingHandOffAndReSyncsLater() {
        for (input, cause) in [(down(), UserInput.mouse), (cmd, .commandKey)] {
            var s = Session(threeUp())
            s.send(.chord(.look(1), repeated: false), at: 0)
            let r = s.send(input, at: 0.1)
            XCTAssertEqual(logs([r]), [.handOffCancelled(cause)])
            s.advance(to: 0.249)
            XCTAssertEqual(count(s.since(), .queryFocus), 0)
            s.advance(to: 0.25)
            XCTAssertEqual(count(s.since(), .queryFocus), 1, "read where focus really landed")
            XCTAssertEqual(focuses(s.since()), [], "the hand-off never fires")
            // The executor answers: focus stayed in the old window, so the focused seat goes back.
            s.send(focus(3), at: 0.26)
            XCTAssertEqual(s.state.table.focusSeat, .C)
        }
    }

    func testInputWithNoPendingHandOffCancelsNothing() {
        let r = Reducer.reduce(threeUp(), cmd, now: 1)
        XCTAssertEqual(r.effects, [])
        XCTAssertNil(r.state.pending.focusResync)
    }

    /// BUGS.md: an app activation inside Strip's pending hand-off loses to it (kept on purpose). The
    /// model now stays with the hand-off instead of following the activation the OS then undoes.
    func testAnAppActivationInsideAPendingHandOffLosesToIt() {
        var s = Session(threeUp())
        s.send(.chord(.look(1), repeated: false), at: 0) // focus seat R (4), hand-off pending
        let r = s.send(focus(2), at: 0.1)                 // `osascript activate`, no user input
        XCTAssertEqual(r.effects, [])
        XCTAssertEqual(s.state.table.focusSeat, .R)
        s.advance(to: 0.17)
        XCTAssertEqual(focuses(s.since()), [4])
        XCTAssertEqual(s.state.handedFocus, 4)
    }

    // MARK: - ⌘Tab into an unlocked satellite: "0, then 2"

    func testCommandKeyFocusIntoASatellitePromotesItAfterTheSettle() {
        var s = Session(threeUp())
        s.send(cmd, at: 0)
        let follow = s.send(focus(4), at: 0.1)
        XCTAssertEqual(follow.plan, .none, "0 moves at first")
        s.advance(to: 0.349)
        XCTAssertEqual(promotes(s.since()), [])
        s.advance(to: 0.35)
        let rs = s.since(0.1)
        XCTAssertEqual(promotes(rs), [.trade(.promote, Trade(a: 4, b: 3, from: .R, to: .C), cut: false, cause: .commandKey)])
        XCTAssertEqual(visible(rs).count, 2)
        XCTAssertTrue(visible(rs).allSatisfy { $0.kind == .spring })
        XCTAssertEqual(s.state.table.seats, [.L: 2, .C: 4, .R: 3])
        XCTAssertEqual(s.state.table.focusSeat, .C)
        XCTAssertEqual(focuses(s.since()), [], "focus is already there")
    }

    func testOnlyTheSatelliteFocusRestsInIsPromoted() {
        var s = Session(threeUp())
        s.send(cmd, at: 0)
        s.send(focus(4), at: 0.1)
        s.send(cmd, at: 0.2)       // ⌘Tab on
        s.send(focus(2), at: 0.3)
        s.advance(to: 2)
        XCTAssertEqual(promotes(s.since()), [.trade(.promote, Trade(a: 2, b: 3, from: .L, to: .C), cut: false, cause: .commandKey)])
    }

    func testFocusMovingOnBeforeTheSettleDropsThePromote() {
        var s = Session(threeUp())
        s.send(cmd, at: 0)
        s.send(focus(4), at: 0.1)
        s.send(focus(3), at: 0.2) // an app put focus back in the center
        s.advance(to: 2)
        XCTAssertEqual(promotes(s.since()), [])
    }

    func testAClickACommandKeyACommandOrTheSettingDropsAPendingPromote() {
        let cancels: [CoreEvent] = [down(), cmd, .chord(.lock, repeated: false), .setting(.clickToCenter(false))]
        for cancel in cancels {
            var s = Session(threeUp())
            s.send(cmd, at: 0)
            s.send(focus(4), at: 0.1)
            s.send(cancel, at: 0.2)
            s.advance(to: 2)
            XCTAssertEqual(promotes(s.since()), [], "\(cancel)")
        }
    }

    func testNoPromoteForAppOrMouseFocusOldInputALockedSeatTheCenterMonocleOrTheSettingOff() {
        func run(_ s0: CoreState, input: CoreEvent?, at inputAt: CFTimeInterval = 0, into id: CGWindowID = 4) -> [LogLine] {
            var s = Session(s0)
            if let input { s.send(input, at: inputAt) }
            s.send(focus(id), at: 1.5)
            s.advance(to: 5)
            return promotes(s.since())
        }
        XCTAssertEqual(run(threeUp(), input: nil), [], "an app activated itself")
        XCTAssertEqual(run(threeUp(), input: down(), at: 1.4), [], "a click waits for the committed-click detector")
        XCTAssertEqual(run(threeUp(), input: cmd, at: 0.4), [], "⌘ more than 1 s before")
        XCTAssertEqual(run(threeUp(), input: cmd, at: 0.5).count, 1, "⌘ exactly 1 s before")
        var locked = threeUp()
        locked.table.locks = [.R]
        XCTAssertEqual(run(locked, input: cmd, at: 1.4), [])
        XCTAssertEqual(run(threeUp(), input: cmd, at: 1.4, into: 3), [], "already the center")
        var monocle = threeUp()
        monocle.table = Table(seats: [.C: 3], pile: [2, 4, 5, 1, 6, 7], cols: 1)
        XCTAssertEqual(run(monocle, input: cmd, at: 1.4), [])
        XCTAssertEqual(run(threeUp(clickToCenter: false), input: cmd, at: 1.4), [])
    }

    // MARK: - Committed clicks: "0, then 2"

    /// A click on satellite `id`: mouseDown, the focus change it causes, mouseUp on the window.
    private func click(_ s: inout Session, _ id: CGWindowID, at t: CFTimeInterval, hit: CGWindowID? = nil,
                       focuses: Bool = true) {
        s.send(down(), at: t)
        if focuses { s.send(focus(id), at: t + 0.05) }
        s.send(up(hit: hit ?? id), at: t + 0.1)
    }

    func testAClickOnASatellitePromotesItOnceTheDoubleClickIntervalPasses() {
        var s = Session(threeUp())
        click(&s, 4, at: 1)
        XCTAssertEqual(plans(s.since()), [], "0 moves at first")
        XCTAssertEqual(s.state.table.focusSeat, .R)
        s.advance(to: 1.599)
        XCTAssertEqual(promotes(s.since()), [])
        s.advance(to: 1.6) // mouseUp + doubleClickInterval
        XCTAssertEqual(promotes(s.since()), [.trade(.promote, Trade(a: 4, b: 3, from: .R, to: .C), cut: false, cause: .click)])
        XCTAssertEqual(visible(s.since()).count, 2)
        XCTAssertTrue(visible(s.since()).allSatisfy { $0.kind == .spring })
        XCTAssertEqual(focuses(s.since()), [])
    }

    func testADockOrNotificationClickThatFocusedASatellitePromotesIt() {
        var s = Session(threeUp())
        s.send(down(), at: 1)
        s.send(up(hit: nil), at: 1.05)    // the Dock: no managed window under the pointer
        s.send(focus(2), at: 1.1)         // focus arrives after the mouseDown
        s.advance(to: 2)
        XCTAssertEqual(promotes(s.since()).count, 1)
        XCTAssertEqual(s.state.table.seats[.C], 2)
    }

    func testAClickElsewhereWhileASatelliteHasFocusDoesNotPromote() {
        for hit: CGWindowID? in [nil, 99] { // the menu bar or desktop; an unmanaged window
            var s = Session(threeUp())
            s.send(focus(4), at: 0)          // an app put focus in R earlier
            s.send(down(), at: 1)
            s.send(up(hit: hit), at: 1.1)    // focus doesn't move
            s.advance(to: 2)
            XCTAssertEqual(promotes(s.since()), [])
            XCTAssertEqual(logs(s.since(0.5)), [.clickNotPromoted(4, seat: .R, locked: false)])
        }
    }

    func testAClickNeverPromotesTheCenterALockedSeatOrWithTheSettingOff() {
        var s = Session(threeUp())
        click(&s, 3, at: 1, focuses: false)
        s.advance(to: 2)
        XCTAssertEqual(logs(s.since()), [], "the center: nothing to say")

        var locked = threeUp()
        locked.table.locks = [.R]
        s = Session(locked)
        click(&s, 4, at: 1)
        s.advance(to: 2)
        XCTAssertEqual(promotes(s.since()), [])
        XCTAssertEqual(logs(s.since(1.06)), [.clickNotPromoted(4, seat: .R, locked: true)])

        s = Session(threeUp(clickToCenter: false))
        click(&s, 4, at: 1)
        XCTAssertNil(s.state.pending.click, "nothing tracked while the setting is off")
        s.advance(to: 2)
        XCTAssertEqual(promotes(s.since()), [])
    }

    func testADragADoubleClickAScrollOrACommandNeverCommits() {
        func run(_ steps: (inout Session) -> Void) -> [LogLine] {
            var s = Session(threeUp())
            s.send(focus(4), at: 0.5)
            steps(&s)
            s.advance(to: 5)
            return promotes(s.since())
        }
        XCTAssertEqual(run { s in
            s.send(self.down(), at: 1); s.send(self.up(CGPoint(x: 3004, y: 600), hit: 4), at: 1.1)
        }, [], "4 pt of travel is a drag")
        XCTAssertEqual(run { s in
            s.send(self.down(), at: 1); s.send(self.up(CGPoint(x: 3003, y: 602), hit: 4), at: 1.1)
        }.count, 1, "under 4 pt is a click")
        XCTAssertEqual(run { s in
            s.send(self.down(), at: 1); s.send(self.up(hit: 4), at: 1.1)
            s.send(self.down(), at: 1.3); s.send(self.up(count: 2, hit: 4), at: 1.35)
        }, [], "a double-click")
        XCTAssertEqual(run { s in
            s.send(self.down(), at: 1); s.send(self.up(hit: 4), at: 1.1); s.send(.userInput(.scroll), at: 1.3)
        }, [])
        XCTAssertEqual(run { s in
            s.send(self.down(), at: 1); s.send(self.up(hit: 4), at: 1.1); s.send(.chord(.toggleEmphasis, repeated: false), at: 1.3)
        }, [])
        XCTAssertEqual(run { s in
            s.send(self.up(hit: 4), at: 1.1)
        }, [], "a mouseUp without its mouseDown")
    }

    // MARK: - External focus into a parked window: "2, cut" or 0

    func testUserCausedFocusIntoAParkedWindowSummonsItAsACut() {
        var s = Session(threeUp())
        s.send(cmd, at: 0)
        let r = s.send(focus(1), at: 0.1)
        XCTAssertEqual(r.plan, .none)
        s.advance(to: 0.219)
        XCTAssertEqual(plans(s.since()), [])
        s.advance(to: 0.22)
        let moves = visible(s.since())
        XCTAssertEqual(moves.map(\.id).sorted(), [1, 3])
        XCTAssertTrue(moves.allSatisfy { $0.kind == .cut })
        XCTAssertEqual(s.state.table.seats[.C], 1)
        XCTAssertEqual(s.state.table.pile.first, 3)
        XCTAssertEqual(logs(s.since()), [.summoned(1, into: nil, displaced: 3)])
        XCTAssertEqual(focuses(s.since()), [], "macOS already focused it")
    }

    func testTheLatestParkedWindowWinsTheCoalesce() {
        var s = Session(threeUp())
        s.send(down(), at: 0)
        s.send(focus(5), at: 0.1)
        s.send(focus(1), at: 0.15)
        s.advance(to: 1)
        XCTAssertEqual(logs(s.since()), [.summoned(1, into: nil, displaced: 3)])
        XCTAssertTrue(s.state.table.pile.contains(5))
    }

    func testFocusLeavingTheParkedWindowDropsTheSummon() {
        var s = Session(threeUp())
        s.send(cmd, at: 0)
        s.send(focus(1), at: 0.1)
        s.send(focus(3), at: 0.15)
        s.advance(to: 1)
        XCTAssertEqual(plans(s.since()), [])
    }

    func testASummonPastALockedCenterLandsInRAndFocusFollowsIt() {
        var locked = threeUp()
        locked.table.locks = [.C]
        var s = Session(locked)
        s.send(cmd, at: 0)
        s.send(focus(1), at: 0.1)
        s.advance(to: 1)
        XCTAssertEqual(s.state.table.seats[.R], 1)
        XCTAssertEqual(s.state.table.focusSeat, .R)
        XCTAssertEqual(logs(s.since()), [.summoned(1, into: .R, displaced: 4)])
        XCTAssertEqual(focuses(s.since()), [], "focus stays where macOS put it")
    }

    func testAppCausedFocusIntoAParkedWindowMovesNothingAndShowsThePill() {
        var s = Session(threeUp())
        let r = s.send(focus(6), at: 5)
        XCTAssertEqual(visible([r]), [])
        XCTAssertEqual(r.plan.steps, [], "a pile reorder writes nothing")
        XCTAssertTrue(r.effects.contains(.pill(.parkedFocus(6))))
        XCTAssertEqual(logs([r]), [.parkedFocus(6)])
        XCTAssertEqual(s.state.table.pile.first, 6, "so ⌃⌥I draws it")
        s.advance(to: 6)
        XCTAssertEqual(plans(s.since(5)), [])

        let draw = s.send(.chord(.draw(.i), repeated: false), at: 7)
        XCTAssertEqual(draw.state.table.seats[.C], 6)
        s.advance(to: 8)
        XCTAssertEqual(focuses(s.since(6.5)), [], "6 already has focus")
    }

    func testThePillTextNamesTheApp() {
        XCTAssertEqual(Pill.parkedFocus(6).text { _ in "Mail" }, "Focus is in parked Mail — ⌃⌥I")
    }

    // MARK: - Settings

    func testTheClickToCenterSettingLogsAndSavesOnlyWhenItChanges() {
        let off = threeUp(clickToCenter: false)
        let on = Reducer.reduce(off, .setting(.clickToCenter(true)), now: 0)
        XCTAssertTrue(on.state.clickToCenter)
        XCTAssertEqual(on.effects, [.log(.clickToCenter(true)), .persist])
        XCTAssertEqual(Reducer.reduce(on.state, .setting(.clickToCenter(true)), now: 1).effects, [])
    }

    // MARK: - Random run

    /// Commands, enumerations, focus changes, clicks, scrolls, ⌘ keys, hints and setting toggles at
    /// random times, with the executor answering `.enumerate` and `.queryFocus`. The table stays
    /// sound, hidden windows are never written, the executor's one timer always matches the earliest
    /// deadline, and no deadline is left overdue.
    func testARandomRunOfInputFocusAndWindowsKeepsTheStateSound() {
        var seen: [String: Int] = [:]
        for seed: UInt64 in 0..<30 {
            let s = randomSession(seed: seed)
            for e in effects(s.since()) {
                switch e {
                case .log(.summoned): seen["summon", default: 0] += 1
                case .log(.trade(.promote, _, _, .commandKey)): seen["⌘ promote", default: 0] += 1
                case .log(.trade(.promote, _, _, .click)): seen["click promote", default: 0] += 1
                case .log(.clickNotPromoted): seen["click refused", default: 0] += 1
                case .log(.handOffCancelled): seen["hand-off cancelled", default: 0] += 1
                case .pill: seen["pill", default: 0] += 1
                case .queryFocus: seen["re-sync", default: 0] += 1
                case .enumerate: seen["re-scan", default: 0] += 1
                case .focus: seen["hand-off", default: 0] += 1
                default: break
                }
            }
        }
        // The run must reach every path it claims to cover.
        for path in ["summon", "⌘ promote", "click promote", "click refused", "hand-off cancelled", "pill",
                     "re-sync", "re-scan", "hand-off"] {
            XCTAssertGreaterThan(seen[path] ?? 0, 0, "the random run never reached: \(path) (\(seen))")
        }
    }

    func testTheRandomRunIsDeterministic() {
        let a = randomSession(seed: 0xF0C5, steps: 300)
        let b = randomSession(seed: 0xF0C5, steps: 300)
        XCTAssertEqual(a.log.map(\.reduction), b.log.map(\.reduction))
        XCTAssertEqual(a.state, b.state)
    }

    private func randomSession(seed: UInt64, steps: Int = 150) -> Session {
        var rng = SplitMix64(seed: seed)
        var s = Session(threeUp(clickToCenter: seed % 3 != 0))
        var next: CGWindowID = 20
        var t: CFTimeInterval = 0
        func snapshot(_ st: CoreState) -> [WindowInfo] {
            st.table.members.map { st.windows[$0] ?? WindowInfo(id: $0, pid: pid($0), frame: st.lastTargets[$0] ?? .zero) }
        }
        for _ in 0..<steps {
            t += [0.01, 0.05, 0.1, 0.13, 0.3, 0.6, 1.2][Int(rng.next() % 7)]
            let members = s.state.table.members
            let any = members.randomElement(using: &rng)
            let event: CoreEvent
            switch rng.next() % 12 {
            case 0: event = .chord([.draw(.i), .draw(.o), .pass(1), .look(-1), .trade(.u), .promote, .lock,
                                    .setCols(Int(rng.next() % 3) + 1)][Int(rng.next() % 8)], repeated: rng.next() % 4 == 0)
            case 1, 2:
                let id = rng.next() % 6 == 0 ? CGWindowID(99) : any
                event = .focusChanged(id, pid: id.map(pid) ?? 0)
            case 3: event = down(CGPoint(x: Double(rng.next() % 8), y: 0))
            case 4: event = up(CGPoint(x: Double(rng.next() % 8), y: 0), count: Int(rng.next() % 2) + 1,
                               hit: rng.next() % 3 == 0 ? nil : any)
            case 5: event = rng.next() % 2 == 0 ? cmd : .userInput(.scroll)
            case 6: event = .membershipHint(pid: Int32(rng.next() % 100))
            case 7: event = .setting(.clickToCenter(rng.next() % 2 == 0))
            case 8:
                let id = next; next += 1
                var list = snapshot(s.state)
                list.insert(WindowInfo(id: id, pid: pid(id), frame: CGRect(x: 900, y: 200, width: 1200, height: 900)), at: 0)
                event = .windowsEnumerated(list, focused: rng.next() % 2 == 0 ? id : s.state.handedFocus)
            case 9:
                var list = snapshot(s.state)
                if let i = list.indices.randomElement(using: &rng) {
                    if rng.next() % 2 == 0 { list.remove(at: i) } else {
                        list[i].visibility = [.shown, .minimized, .hidden][Int(rng.next() % 3)]
                    }
                }
                event = .windowsEnumerated(list, focused: s.state.handedFocus)
            default: event = .tick
            }
            let r = s.send(event, at: t)
            // The executor answers what the reducer asked for, at once.
            if r.effects.contains(.enumerate) {
                s.send(.windowsEnumerated(snapshot(s.state), focused: s.state.handedFocus), at: t)
            }
            if r.effects.contains(.queryFocus), let f = s.state.handedFocus {
                s.send(focus(f), at: t)
            }
            check(s, seed: seed)
        }
        s.advance(to: t + 5)
        XCTAssertNil(s.state.pending.earliest, "seed \(seed): a deadline never fired")
        return s
    }

    private func check(_ s: Session, seed: UInt64, file: StaticString = #filePath, line: UInt = #line) {
        let st = s.state
        XCTAssertEqual(st.table.invariantViolations(), [], "seed \(seed)", file: file, line: line)
        for entry in s.log.suffix(3) {
            let hidden = Set(entry.reduction.state.windows.filter { $0.value.visibility != .shown }.keys)
            XCTAssertTrue(entry.reduction.plan.ids.isDisjoint(with: hidden), "seed \(seed): a hidden window was written",
                          file: file, line: line)
        }
        let members = Set(st.table.members)
        XCTAssertTrue(Set(st.windows.keys).isSubset(of: members), file: file, line: line)
        XCTAssertTrue(Set(st.recent).isSubset(of: members), file: file, line: line)
        if let earliest = st.pending.earliest {
            XCTAssertEqual(s.timer, earliest, "seed \(seed): the executor's timer is stale", file: file, line: line)
            XCTAssertGreaterThan(earliest, s.clock - Timing.slack, "seed \(seed): an overdue deadline", file: file, line: line)
        }
    }
}

extension LogLineTests {
    func testFocusAndClickLines() {
        let names: [CGWindowID: String] = [3: "Safari", 4: "Terminal", 5: "Mail"]
        func text(_ l: LogLine) -> String { l.text { names[$0] ?? "?" } }
        XCTAssertEqual(text(.focusFollow(4, seat: .R)), "focus-follow: Terminal → slot R")
        XCTAssertEqual(text(.handOffCancelled(.commandKey)), "focus hand-off cancelled ← ⌘ key")
        XCTAssertEqual(text(.handOffCancelled(.mouse)), "focus hand-off cancelled ← mouseDown")
        XCTAssertEqual(text(.parkedFocus(5)), "parked-focus: Mail focused without user input — left parked")
        XCTAssertEqual(text(.summoned(5, into: nil, displaced: 3)), "summon: Mail → center (swapped with Safari)")
        XCTAssertEqual(text(.summoned(5, into: .R, displaced: nil)), "summon: Mail → R")
        XCTAssertEqual(text(.clickNotPromoted(4, seat: .R, locked: true)),
                       "click: committed in Terminal (R) — not promoted (locked seat)")
        XCTAssertEqual(text(.clickNotPromoted(4, seat: .L, locked: false)),
                       "click: committed in Terminal (L) — not promoted (the click didn't land on it)")
        XCTAssertEqual(text(.clickToCenter(true)), "click-to-center: on")
        XCTAssertEqual(text(.trade(.promote, Trade(a: 4, b: 3, from: .R, to: .C), cut: false, cause: .click)),
                       "promote: Terminal R → C, Safari C → R (spring) ← click")
    }
}

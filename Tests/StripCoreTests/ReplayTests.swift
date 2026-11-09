import XCTest
import CoreGraphics
@testable import StripCore

/// Recorded sessions (Seats & Pile step 2, commit 6): every event survives its `EV` line, a session
/// read back out of a log replays to the same reductions, and `Replay.run` checks every invariant
/// after every step.
final class ReplayTests: XCTestCase {
    let start = Replay.Start(vis: CGRect(x: 0, y: 25, width: 3440, height: 1415), clickToCenter: true)
    let frame = CGRect(x: 900, y: 200, width: 1200, height: 900)

    // MARK: - Lines

    /// One of each event, command and input, with awkward values (nil, fractions, negatives).
    private var samples: [CoreEvent] {
        let w = WindowInfo(id: 9, pid: 90, frame: CGRect(x: -1300.5, y: 25, width: 1200.25, height: 900),
                           visibility: .minimized, steps: true)
        let commands: [Command] = [.draw(.u), .trade(.o), .promote, .pick(5, into: nil), .pick(5, into: .i), .pass(-1),
                                   .look(1), .lock, .setCols(2), .setEmphasis(.equal), .toggleEmphasis,
                                   .adjustFocusRatio(-0.05), .adjustHeight(0.05), .adjustGap(4)]
        let inputs: [InputEvent] = [.mouseDown(at: CGPoint(x: 10.5, y: -3)),
                                    .mouseUp(at: CGPoint(x: 11, y: -3), clickCount: 2, hit: 4, doubleClickInterval: 0.35),
                                    .mouseUp(at: .zero, clickCount: 1, hit: nil, doubleClickInterval: 0.5),
                                    .scroll, .commandKey]
        return commands.map { .chord($0, repeated: false) } + [.chord(.pass(1), repeated: true)]
            + inputs.map { .userInput($0) } + [
                .windowsEnumerated([w, WindowInfo(id: 3, frame: frame)], focused: 3),
                .windowsEnumerated([], focused: nil),
                .tabReplaced(old: 3, new: w),
                .displayChanged(vis: start.vis, displays: [start.vis, CGRect(x: -2560, y: 0, width: 2560, height: 1440)]),
                .dragEnded(4, wasResize: true, frame: frame),
                .frameClamped(4, requested: frame, actual: frame.insetBy(dx: 10, dy: 0)),
                .writeFailed(4),
                .focusChanged(4, pid: 40), .focusChanged(nil, pid: 40),
                .membershipHint(pid: 7),
                .setting(.clickToCenter(true)),
                .tick,
            ]
    }

    /// The case name of an event. No `default`: a new event fails to compile here until it has a
    /// sample above.
    private func name(_ e: CoreEvent) -> String {
        switch e {
        case .chord: return "chord"
        case .windowsEnumerated: return "windowsEnumerated"
        case .tabReplaced: return "tabReplaced"
        case .displayChanged: return "displayChanged"
        case .dragEnded: return "dragEnded"
        case .frameClamped: return "frameClamped"
        case .writeFailed: return "writeFailed"
        case .focusChanged: return "focusChanged"
        case .userInput: return "userInput"
        case .membershipHint: return "membershipHint"
        case .setting: return "setting"
        case .tick: return "tick"
        }
    }

    func testEveryEventSurvivesItsLogLine() {
        XCTAssertEqual(Set(samples.map(name)).count, 12, "a sample for every event")
        for (i, e) in samples.enumerated() {
            let t = 1000 + Double(i) * 0.0137 + 1e-9
            let log = Replay.line(start) + "\n" + Replay.line(e, at: t)
            let sessions = Replay.sessions(in: log)
            XCTAssertEqual(sessions, [Replay.Recording(start: start, events: [.init(e, at: t)])], Replay.line(e, at: t))
        }
    }

    func testTheStartLineCarriesTheSettings() {
        var config = LayoutConfig.default
        config.focusRatio = 0.62
        config.newWindowPlacement = .append
        let s = Replay.Start(vis: start.vis, displays: [start.vis], cols: 2, emphasis: .equal, config: config,
                             clickToCenter: false)
        XCTAssertEqual(Replay.sessions(in: Replay.line(s)).first?.start, s)
        let state = s.state
        XCTAssertEqual(state.table.cols, 2)
        XCTAssertEqual(state.table.focusSeat, .L)
        XCTAssertEqual(state.table.config, config)
        XCTAssertEqual(state.table.members, [])
    }

    func testReadingALogSkipsOtherLinesAndSplitsSessionsAtEachStart() {
        let log = """
        16:20:00.000 EV 1.0 {"tick":{}}
        16:20:00.001 \(Replay.line(start))
        16:20:00.002 draw: Mail → C (Safari to the pile)
        16:20:00.003 EV 2.5 {"tick":{}}
        16:20:00.004 EV 2.6 {"nonsense":{}}
        16:20:00.005 EV oops {"tick":{}}
        \(Replay.line(start))
        EV 3.0 {"membershipHint":{"pid":3}}
        """
        let sessions = Replay.sessions(in: log)
        XCTAssertEqual(sessions.map(\.events), [[.init(.tick, at: 2.5)], [.init(.membershipHint(pid: 3), at: 3)]])
    }

    // MARK: - A recorded session

    /// A morning, as `/tmp/strip.log` would hold it: startup adopts six windows; ⌃⌥I draws 14 into
    /// the center and hands it focus; ⌘Tab into R promotes 12 after the settle; ⌘Tab into parked 15
    /// summons it; an app focuses parked 16 by itself (the pill); 13 closes, and the debounced
    /// re-scan finds it gone and refills L.
    private let fixture = #"""
    09:00:00.000 Strip started
    09:00:00.001 ST {"clickToCenter":true,"cols":3,"config":{"focusRatio":0.5,"heightFraction":1,"innerGap":8,"monocleWidthFraction":0.6,"newWindowPlacement":"focusCenter","outerPadding":8},"displays":[],"emphasis":"focus","vis":[[0,25],[3440,1415]]}
    09:00:00.002 EV 100.0 {"windowsEnumerated":{"_0":[{"frame":[[900,200],[1200,900]],"id":11,"pid":110,"steps":false,"visibility":"shown"},{"frame":[[900,200],[1200,900]],"id":12,"pid":120,"steps":false,"visibility":"shown"},{"frame":[[900,200],[1200,900]],"id":13,"pid":130,"steps":false,"visibility":"shown"},{"frame":[[900,200],[1200,900]],"id":14,"pid":140,"steps":false,"visibility":"shown"},{"frame":[[900,200],[1200,900]],"id":15,"pid":150,"steps":false,"visibility":"shown"},{"frame":[[900,200],[1200,900]],"id":16,"pid":160,"steps":false,"visibility":"shown"}],"focused":11}}
    09:00:00.003 adopt: 6 window(s)
    09:00:00.500 EV 100.5 {"chord":{"_0":{"draw":{"_0":"i"}},"repeated":false}}
    09:00:00.670 EV 100.67 {"tick":{}}
    09:00:01.000 EV 101.0 {"userInput":{"_0":{"commandKey":{}}}}
    09:00:01.100 EV 101.1 {"focusChanged":{"_0":12,"pid":120}}
    09:00:01.350 EV 101.35 {"tick":{}}
    09:00:02.000 EV 102.0 {"userInput":{"_0":{"commandKey":{}}}}
    09:00:02.100 EV 102.1 {"focusChanged":{"_0":15,"pid":150}}
    09:00:02.220 EV 102.22 {"tick":{}}
    09:00:04.000 EV 104.0 {"focusChanged":{"_0":16,"pid":160}}
    09:00:05.000 EV 105.0 {"membershipHint":{"pid":130}}
    09:00:05.075 EV 105.075 {"tick":{}}
    09:00:05.100 EV 105.1 {"windowsEnumerated":{"_0":[{"frame":[[900,200],[1200,900]],"id":15,"pid":150,"steps":false,"visibility":"shown"},{"frame":[[900,200],[1200,900]],"id":16,"pid":160,"steps":false,"visibility":"shown"},{"frame":[[900,200],[1200,900]],"id":12,"pid":120,"steps":false,"visibility":"shown"},{"frame":[[900,200],[1200,900]],"id":14,"pid":140,"steps":false,"visibility":"shown"},{"frame":[[900,200],[1200,900]],"id":11,"pid":110,"steps":false,"visibility":"shown"}],"focused":15}}
    """#

    private func logs(_ r: Reduction) -> [LogLine] {
        r.effects.compactMap { if case let .log(l) = $0 { return l } else { return nil } }
    }

    func testARecordedSessionReplays() throws {
        let recording = try XCTUnwrap(Replay.sessions(in: fixture).first)
        XCTAssertEqual(recording.events.count, 13)
        let result = Replay.run(recording)
        XCTAssertNil(result.failure)
        let steps = result.reductions

        XCTAssertEqual(steps[0].state.table.seats, [.L: 13, .C: 11, .R: 12])
        XCTAssertEqual(logs(steps[1]), [.draw(drawn: 14, displaced: 11, seat: .C)])
        XCTAssertEqual(steps[2].effects.filter { if case .focus = $0 { return true } else { return false } }, [.focus(14)])
        XCTAssertEqual(logs(steps[4]), [.focusFollow(12, seat: .R)])
        XCTAssertEqual(steps[4].plan, .none)
        XCTAssertEqual(logs(steps[5]), [.trade(.promote, Trade(a: 12, b: 14, from: .R, to: .C), cut: false, cause: .commandKey)])
        XCTAssertEqual(steps[5].plan.steps.map(\.kind), [.spring, .spring])
        XCTAssertEqual(logs(steps[8]), [.summoned(15, into: nil, displaced: 12)])
        XCTAssertTrue(steps[9].effects.contains(.pill(.parkedFocus(16))))
        XCTAssertTrue(steps[11].effects.contains(.enumerate))
        XCTAssertEqual(logs(steps[12]), [.closed(13, refill: 16)])

        XCTAssertEqual(result.state.table.seats, [.L: 16, .C: 15, .R: 14])
        XCTAssertEqual(result.state.table.pile, [12, 11])
        XCTAssertEqual(result.state.handedFocus, 15)
    }

    func testAReplayIsDeterministic() throws {
        let recording = try XCTUnwrap(Replay.sessions(in: fixture).first)
        XCTAssertEqual(Replay.run(recording), Replay.run(recording))
    }

    func testAReplayStopsAtTheFirstBrokenInvariant() {
        var bad = start.state
        bad.table = Table(seats: [.L: 2, .C: 2])   // 2 in two places
        let result = Replay.run(from: bad, [.init(.tick, at: 1), .init(.tick, at: 2)])
        XCTAssertEqual(result.failure?.index, 0)
        XCTAssertEqual(result.failure?.violations, ["window 2 is in 2 places"])
        XCTAssertEqual(result.reductions.count, 1)
    }

    // MARK: - A long seeded session

    /// Two thousand random events (every type, the executor answering what the reducer asks) are
    /// written as log lines, read back and replayed: the replay reproduces every reduction, and no
    /// step breaks an invariant.
    func testALongSeededSessionRoundTripsThroughTheLog() throws {
        var work = Workload(seed: 0x10C, maxWindows: 14)
        var live = Session(start.state)
        live.send(.windowsEnumerated([WindowInfo(id: 1, pid: 10, frame: frame)], focused: 1), at: 0)
        for _ in 0..<2000 {
            let (t, e) = work.next(live.state)
            live.drive(e, at: t)
        }
        let text = ([Replay.line(start)] + live.log.map { Replay.line($0.event, at: $0.at) }).joined(separator: "\n")
        let recording = try XCTUnwrap(Replay.sessions(in: text).first)
        XCTAssertEqual(recording.events.count, live.log.count)
        let result = Replay.run(recording)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.reductions, live.log.map(\.reduction))
        XCTAssertEqual(result.state, live.state)
    }
}

/// How long one `Reducer.reduce` takes over a long mixed session (no threshold: the numbers go in
/// the commit and MEASURING.md). Ten thousand events from the seeded workload with at most 12
/// windows, the executor answering the reducer, are recorded first and then timed one by one.
/// Reports p50 / p90 / max in microseconds. Set STRIP_BENCH_EVENTS to change the count.
final class ReduceBenchmarkTests: XCTestCase {
    func testReduceTimings() {
        let n = ProcessInfo.processInfo.environment["STRIP_BENCH_EVENTS"].flatMap(Int.init) ?? 10_000
        let start = Replay.Start(vis: CGRect(x: 0, y: 25, width: 3440, height: 1415), clickToCenter: true)
        var work = Workload(seed: 0xBE7C4, maxWindows: 12)
        var live = Session(start.state)
        live.send(.windowsEnumerated([WindowInfo(id: 1, pid: 10, frame: CGRect(x: 900, y: 200, width: 1200, height: 900))],
                                     focused: 1), at: 0)
        while live.log.count < n {
            let (t, e) = work.next(live.state)
            live.drive(e, at: t)
        }
        var state = start.state
        var ns: [UInt64] = []
        var windows = 0
        ns.reserveCapacity(live.log.count)
        for entry in live.log {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let r = Reducer.reduce(state, entry.event, now: entry.at)
            ns.append(DispatchTime.now().uptimeNanoseconds - t0)
            state = r.state
            windows += state.table.members.count
        }
        XCTAssertEqual(state, live.state)
        ns.sort()
        func us(_ q: Double) -> String {
            String(format: "%.1f", Double(ns[min(ns.count - 1, Int(Double(ns.count) * q))]) / 1000)
        }
        print("reduce benchmark: n=\(ns.count) windows≈\(windows / ns.count) p50=\(us(0.5))µs p90=\(us(0.9))µs "
              + "p99=\(us(0.99))µs max=\(String(format: "%.1f", Double(ns.last ?? 0) / 1000))µs")
    }
}

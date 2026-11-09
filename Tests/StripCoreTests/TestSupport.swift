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

    /// Send `event` at `t` and answer what the reducer asks of the executor, at once: `.enumerate`
    /// with a snapshot of the managed windows, `.queryFocus` with the focus it already tracks.
    mutating func drive(_ event: CoreEvent, at t: CFTimeInterval) {
        let r = send(event, at: t)
        if r.effects.contains(.enumerate) {
            send(.windowsEnumerated(Fixture.snapshot(state), focused: state.handedFocus), at: t)
        }
        if r.effects.contains(.queryFocus), let f = state.handedFocus {
            send(.focusChanged(f, pid: Fixture.pid(f)), at: t)
        }
    }

    /// Reductions after time `t` (exclusive), or all.
    func since(_ t: CFTimeInterval = -.infinity) -> [Reduction] {
        log.filter { $0.at > t }.map(\.reduction)
    }
}

enum Fixture {
    static let stage = Stage(vis: CGRect(x: 0, y: 25, width: 3440, height: 1415))

    /// Window n lives in app pid 10n.
    static func pid(_ id: CGWindowID) -> Int32 { Int32(id) * 10 }

    /// 3-up: L=2 C=3 R=4; pile 5, 1, 6, 7; every window where the reducer put it; 3 has focus.
    static func threeUp(stage: Stage = stage, clickToCenter: Bool = true) -> CoreState {
        var s = CoreState(table: Table(seats: [.L: 2, .C: 3, .R: 4], pile: [5, 1, 6, 7]), stage: stage)
        s.lastTargets = s.table.targets(on: stage, parkEdges: s.parkEdges)
        for (id, f) in s.lastTargets { s.windows[id] = WindowInfo(id: id, pid: pid(id), frame: f) }
        s.handedFocus = 3
        s.recent = [3]
        s.clickToCenter = clickToCenter
        return s
    }

    /// What an enumeration of `s` reports: every managed window, as last seen or where the reducer
    /// last put it.
    static func snapshot(_ s: CoreState) -> [WindowInfo] {
        s.table.members.map { s.windows[$0] ?? WindowInfo(id: $0, pid: pid($0), frame: s.lastTargets[$0] ?? .zero) }
    }
}

/// A seeded random stream of every event type, each picked against the current state: commands
/// (some held), focus changes (managed, unknown, unreadable), clicks, scrolls, ⌘ keys, membership
/// hints, setting toggles, new / closed / hidden / restored windows, and stray ticks, at irregular
/// times. The random walks and the reduce benchmark run on it.
struct Workload {
    var rng: SplitMix64
    var t: CFTimeInterval = 0
    /// No new windows open while this many are managed.
    var maxWindows: Int
    private var nextId: CGWindowID = 20

    init(seed: UInt64, maxWindows: Int = .max) {
        rng = SplitMix64(seed: seed)
        self.maxWindows = maxWindows
    }

    mutating func next(_ s: CoreState) -> (CFTimeInterval, CoreEvent) {
        t += [0.01, 0.05, 0.1, 0.13, 0.3, 0.6, 1.2][Int(rng.next() % 7)]
        let any = s.table.members.randomElement(using: &rng)
        let p = CGPoint(x: Double(rng.next() % 8), y: 0)
        let event: CoreEvent
        switch rng.next() % 12 {
        case 0:
            let c: [Command] = [.draw(.i), .draw(.o), .pass(1), .look(-1), .trade(.u), .promote, .lock,
                                .setCols(Int(rng.next() % 3) + 1)]
            event = .chord(c[Int(rng.next() % 8)], repeated: rng.next() % 4 == 0)
        case 1, 2:
            let id = rng.next() % 6 == 0 ? CGWindowID(99) : any
            event = .focusChanged(id, pid: id.map(Fixture.pid) ?? 0)
        case 3: event = .userInput(.mouseDown(at: p))
        case 4: event = .userInput(.mouseUp(at: p, clickCount: Int(rng.next() % 2) + 1,
                                            hit: rng.next() % 3 == 0 ? nil : any, doubleClickInterval: 0.5))
        case 5: event = .userInput(rng.next() % 2 == 0 ? .commandKey : .scroll)
        case 6: event = .membershipHint(pid: Int32(rng.next() % 100))
        case 7: event = .setting(.clickToCenter(rng.next() % 2 == 0))
        case 8 where s.table.members.count < maxWindows:
            let id = nextId
            nextId += 1
            var list = Fixture.snapshot(s)
            list.insert(WindowInfo(id: id, pid: Fixture.pid(id), frame: CGRect(x: 900, y: 200, width: 1200, height: 900)), at: 0)
            event = .windowsEnumerated(list, focused: rng.next() % 2 == 0 ? id : s.handedFocus)
        case 9:
            var list = Fixture.snapshot(s)
            if let i = list.indices.randomElement(using: &rng) {
                if rng.next() % 2 == 0 {
                    list.remove(at: i)
                } else {
                    list[i].visibility = [.shown, .minimized, .hidden][Int(rng.next() % 3)]
                }
            }
            event = .windowsEnumerated(list, focused: s.handedFocus)
        default: event = .tick
        }
        return (t, event)
    }
}

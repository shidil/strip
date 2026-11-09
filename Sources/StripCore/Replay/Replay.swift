import CoreGraphics
import Foundation

/// Record and replay reducer sessions (`docs/design/seats-and-pile.md`, *Core architecture*: "every
/// event is logged in a replayable form, so a recorded session from `/tmp/strip.log` becomes a unit
/// test").
///
/// The executor logs one `ST <json>` line when it builds the first state (`Start`), then one
/// `EV <t> <json>` line per event, `t` being the media time it passed as `now`. `sessions(in:)`
/// reads them back out of a log (other lines and the log's own timestamps are skipped; each `ST`
/// starts a new session), and `run` replays one, checking every invariant after every step.
public enum Replay {
    /// What a session starts from: the display and the persisted settings. The table starts empty;
    /// the first enumeration adopts the windows.
    public struct Start: Equatable, Codable {
        public var vis: CGRect
        public var displays: [CGRect]
        public var cols: Int
        public var emphasis: Emphasis
        public var config: LayoutConfig
        public var clickToCenter: Bool

        public init(vis: CGRect, displays: [CGRect] = [], cols: Int = 3, emphasis: Emphasis = .focus,
                    config: LayoutConfig = .default, clickToCenter: Bool = false) {
            self.vis = vis
            self.displays = displays
            self.cols = cols
            self.emphasis = emphasis
            self.config = config
            self.clickToCenter = clickToCenter
        }

        /// The state a session begins in.
        public var state: CoreState {
            var s = CoreState(table: Table(cols: cols, emphasis: emphasis, config: config),
                              stage: Stage(vis: vis, displays: displays))
            s.clickToCenter = clickToCenter
            return s
        }
    }

    /// One event and the time it happened.
    public struct Timed: Equatable {
        public var at: CFTimeInterval
        public var event: CoreEvent

        public init(_ event: CoreEvent, at: CFTimeInterval) {
            self.at = at
            self.event = event
        }
    }

    /// A recorded session.
    public struct Recording: Equatable {
        public var start: Start
        public var events: [Timed]

        public init(start: Start, events: [Timed] = []) {
            self.start = start
            self.events = events
        }
    }

    /// The step a replay stopped at, and what broke.
    public struct Failure: Equatable {
        public var index: Int
        public var event: Timed
        public var violations: [String]
    }

    /// What a replay produced.
    public struct Result: Equatable {
        /// The state after the last step that ran.
        public var state: CoreState
        /// Every step's reduction, in order.
        public var reductions: [Reduction]
        /// The first step that broke an invariant; the replay stops there.
        public var failure: Failure?
    }

    // MARK: - Lines

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// The `ST <json>` line that starts a session.
    public static func line(_ start: Start) -> String {
        "ST " + json(start)
    }

    /// The `EV <t> <json>` line for `event` at media time `t`.
    public static func line(_ event: CoreEvent, at t: CFTimeInterval) -> String {
        "EV \(t) " + json(event)
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        // Every logged type encodes; a failure is a programming error in a Codable conformance.
        String(decoding: (try? encoder.encode(value)) ?? Data("null".utf8), as: UTF8.self)
    }

    /// The sessions in a log: each `ST` line starts one and the `EV` lines after it are its events.
    /// Anything else (other log lines, `EV` lines before the first `ST`, unreadable lines) is
    /// skipped. A log line may carry a timestamp before the tag.
    public static func sessions(in log: String) -> [Recording] {
        let decoder = JSONDecoder()
        var out: [Recording] = []
        for raw in log.split(whereSeparator: \.isNewline) {
            var words = raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if let first = words.first, first != "ST", first != "EV" {
                words = raw.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).dropFirst().map { $0 }
            }
            guard let tag = words.first else { continue }
            if tag == "ST", words.count >= 2 {
                let body = words.dropFirst().joined(separator: " ")
                if let start = try? decoder.decode(Start.self, from: Data(body.utf8)) {
                    out.append(Recording(start: start))
                }
            } else if tag == "EV", words.count == 3, !out.isEmpty, let t = Double(words[1]),
                      let event = try? decoder.decode(CoreEvent.self, from: Data(words[2].utf8)) {
                out[out.count - 1].events.append(Timed(event, at: t))
            }
        }
        return out
    }

    // MARK: - Running

    /// Replay `recording` from its start.
    public static func run(_ recording: Recording) -> Result {
        run(from: recording.start.state, recording.events)
    }

    /// Replay `events` from `state`, checking `Reduction.invariantViolations()` after every step.
    public static func run(from state: CoreState, _ events: [Timed]) -> Result {
        var result = Result(state: state, reductions: [], failure: nil)
        for (i, e) in events.enumerated() {
            let r = Reducer.reduce(result.state, e.event, now: e.at)
            result.reductions.append(r)
            result.state = r.state
            let broken = r.invariantViolations()
            if !broken.isEmpty {
                result.failure = Failure(index: i, event: e, violations: broken)
                break
            }
        }
        return result
    }
}

public extension Reduction {
    /// Every broken invariant after this step: the table's own (`Table.invariantViolations()`), the
    /// reducer's bookkeeping (frames, windows, constraints, recency and focus only for managed
    /// windows; a park edge for exactly the pile), and a plan that never writes a hidden window.
    func invariantViolations() -> [String] {
        var out = state.table.invariantViolations()
        let members = Set(state.table.members)
        func extra<C: Sequence>(_ name: String, _ ids: C) where C.Element == CGWindowID {
            let stray = Set(ids).subtracting(members).sorted()
            if !stray.isEmpty { out.append("\(name) lists unmanaged windows \(stray)") }
        }
        extra("lastTargets", state.lastTargets.keys)
        extra("windows", state.windows.keys)
        extra("constraints", state.stage.constraints.keys)
        extra("recent", state.recent)
        if let h = state.handedFocus, !members.contains(h) { out.append("handedFocus \(h) isn't managed") }
        if Set(state.parkEdges.keys) != Set(state.table.pile) { out.append("park edges don't match the pile") }
        let hidden = state.windows.filter { $0.value.visibility != .shown }.keys
        let written = plan.ids.intersection(hidden).sorted()
        if !written.isEmpty { out.append("the plan writes hidden windows \(written)") }
        return out
    }
}

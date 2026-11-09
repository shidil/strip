import Foundation

/// Holds the reducer's state and runs each event through `Reducer.reduce` for the executor (Seats &
/// Pile step 3). StripCore stays free of `os`, so the `reduce` signpost interval lives here: the
/// perf guard on the hot path of every event (`docs/design/seats-and-pile.md`, *Core
/// architecture*; MEASURING.md).
///
/// With a `record` sink, it writes the session's `ST` line at init and an `EV` line per event
/// (`Replay`), so a session in `/tmp/strip.log` replays as a test.
public final class CoreDriver {
    public private(set) var state: CoreState
    private let record: ((String) -> Void)?

    public init(_ start: Replay.Start, record: ((String) -> Void)? = nil) {
        state = start.state
        self.record = record
        record?(Replay.line(start))
    }

    /// Reduce `event` at media time `now`, adopt the new state, and return the reduction for the
    /// executor to run (its plan and effects).
    @discardableResult
    public func send(_ event: CoreEvent, now: CFTimeInterval) -> Reduction {
        record?(Replay.line(event, at: now))
        let sp = Signpost.log.beginInterval("reduce")
        let r = Reducer.reduce(state, event, now: now)
        Signpost.log.endInterval("reduce", sp, "steps=\(r.plan.steps.count) effects=\(r.effects.count)")
        state = r.state
        return r
    }
}

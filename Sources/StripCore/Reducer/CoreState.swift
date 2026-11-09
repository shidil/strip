import CoreGraphics
import Foundation

/// The timings the reducer owns. Time is an input (`Reducer.reduce(_:_:now:)`), so each of these is
/// a tested policy rather than a timer in the controller.
public enum Timing {
    /// Focus rests this long before the reducer hands it to the window (`SideEffect.focus`), so a
    /// fast run of passes or looks focuses only the window you stop on. (`StripController.focusSettleDelay`.)
    public static let focusSettle: CFTimeInterval = 0.17
    /// A held pass or look key steps at most this often; the latest direction wins and surplus
    /// repeats are dropped. (`StripController.minNavInterval`.)
    public static let navInterval: CFTimeInterval = 0.20
    /// A deadline counts as due this early, so a tick that lands a hair before it still fires it.
    static let slack: CFTimeInterval = 0.001
}

/// A value waiting for its time.
public struct Deadline<Value: Equatable>: Equatable {
    public var value: Value
    public var at: CFTimeInterval

    public init(_ value: Value, at: CFTimeInterval) {
        self.value = value
        self.at = at
    }

    func isDue(_ now: CFTimeInterval) -> Bool { now >= at - Timing.slack }
}

/// Work waiting for a time.
public struct Pending: Equatable {
    /// Hand keyboard focus to this window once focus has rested (`Timing.focusSettle`).
    public var focusHandOff: Deadline<CGWindowID>?
    /// A held pass or look waiting for its turn (`Timing.navInterval`).
    public var nav: Deadline<Command>?
    /// When the last pass or look ran.
    public var lastNavAt: CFTimeInterval = -.infinity

    public init() {}

    /// The earliest deadline, if any.
    public var earliest: CFTimeInterval? {
        [focusHandOff?.at, nav?.at].compactMap { $0 }.min()
    }
}

/// Everything the reducer knows. Equatable, so a replay can compare states step by step.
public struct CoreState: Equatable {
    public var table: Table
    public var stage: Stage
    /// The park edge of each pile card (`Table.parkEdges`).
    public var parkEdges: [CGWindowID: Edge]
    /// The frame the reducer last commanded for each window. A plan starts from these; a window
    /// missing here is assumed to be at its target on the current table.
    public var lastTargets: [CGWindowID: CGRect]
    /// The window Strip last handed keyboard focus to (or that macOS reported focused).
    public var handedFocus: CGWindowID?
    public var pending: Pending

    public init(table: Table = Table(), stage: Stage) {
        self.table = table
        self.stage = stage
        self.parkEdges = Table.parkEdges([:], from: table, to: table)
        self.lastTargets = [:]
        self.handedFocus = nil
        self.pending = Pending()
    }
}

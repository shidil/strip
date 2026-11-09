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
    /// A focus change for the app Strip just activated counts as Strip's own this long after the
    /// activation (`WindowObserver.selfActivationGrace`), unless the user clicked or pressed ⌘ since.
    public static let ownActivationGrace: CFTimeInterval = 0.2
    /// After a click or ⌘ key cancels a hand-off, ask where focus really landed this much later
    /// (`StripController.focusResyncDelay`): a click back into the focused window, or a plain ⌘
    /// shortcut, posts no focus change of its own.
    public static let focusResync: CFTimeInterval = 0.15
    /// Membership hints come in bursts; re-enumerate this long after the last one
    /// (`WindowObserver.debounceInterval`).
    public static let rescanDebounce: CFTimeInterval = 0.075
    /// User-caused focus into a parked window waits this long, latest window wins, before it is
    /// summoned.
    public static let parkedCoalesce: CFTimeInterval = 0.12
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

/// A value and when it happened.
public struct Stamp<Value: Equatable>: Equatable {
    public var value: Value
    public var at: CFTimeInterval

    public init(_ value: Value, at: CFTimeInterval) {
        self.value = value
        self.at = at
    }
}

/// Work waiting for a time.
public struct Pending: Equatable {
    /// Hand keyboard focus to this window once focus has rested (`Timing.focusSettle`).
    public var focusHandOff: Deadline<CGWindowID>?
    /// A held pass or look waiting for its turn (`Timing.navInterval`).
    public var nav: Deadline<Command>?
    /// When the last pass or look ran.
    public var lastNavAt: CFTimeInterval = -.infinity
    /// A click or ⌘ key cancelled a hand-off: emit `SideEffect.queryFocus` at this time.
    public var focusResync: CFTimeInterval?
    /// A membership hint arrived: emit `SideEffect.enumerate` at this time (trailing).
    public var rescan: CFTimeInterval?
    /// The user focused this parked window: summon it if focus is still there
    /// (`Timing.parkedCoalesce`).
    public var summon: Deadline<CGWindowID>?
    /// ⌘ put focus in this unlocked satellite: promote it if focus is still there
    /// (`PromotePolicy.commandKeySettle`).
    public var promote: Deadline<CGWindowID>?
    /// A single still click waits out the double-click interval; the value is the window it landed
    /// on (`InputEvent.mouseUp`'s `hit`).
    public var click: Deadline<CGWindowID?>?

    public init() {}

    /// The earliest deadline, if any.
    public var earliest: CFTimeInterval? {
        [focusHandOff?.at, nav?.at, focusResync, rescan, summon?.at, promote?.at, click?.at].compactMap { $0 }.min()
    }
}

/// What the reducer remembers about the user's own input: it attributes focus changes
/// (`PromotePolicy.attribution`) and detects committed clicks.
public struct InputState: Equatable {
    /// The user's last click or ⌘ key, and when.
    public var last: UserInput?
    public var lastAt: CFTimeInterval = -.infinity
    /// When the user last pressed the left mouse button outside Strip.
    public var lastMouseDownAt: CFTimeInterval = -.infinity
    /// The window macOS focus last arrived in from outside Strip, and when.
    public var arrival: Stamp<CGWindowID>?
    /// The app Strip last activated (a hand-off), and when.
    public var ownActivation: Stamp<Int32>?
    /// The committed-click detector (only fed while click-to-center is on).
    public var clicks = ClickCommitTracker()

    public init() {}
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
    /// What the last enumeration said about each managed window.
    public var windows: [CGWindowID: WindowInfo]
    /// Managed windows by when they last had focus, most recent first (picks the satellite that
    /// refills an empty center).
    public var recent: [CGWindowID]
    public var pending: Pending
    /// "Center on click or ⌘Tab" (`Setting.clickToCenter`).
    public var clickToCenter: Bool
    public var input: InputState

    public init(table: Table = Table(), stage: Stage) {
        self.table = table
        self.stage = stage
        self.parkEdges = Table.parkEdges([:], from: table, to: table)
        self.lastTargets = [:]
        self.handedFocus = nil
        self.windows = [:]
        self.recent = []
        self.pending = Pending()
        self.clickToCenter = false
        self.input = InputState()
    }
}

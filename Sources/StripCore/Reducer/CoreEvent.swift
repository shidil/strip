import CoreGraphics

/// A user command the reducer acts on (`docs/design/seats-and-pile.md`, *Interactions*). Commands
/// that only touch Strip's own chrome or the animator (Overview, help, search, the spring preset,
/// release-all) stay in the executor.
public enum Command: Equatable {
    /// ⌃⌥U / I / O: draw `pile[0]` into the seat the key names.
    case draw(SeatKey)
    /// ⌃⌥⇧U / I / O: trade the focused window with that seat.
    case trade(SeatKey)
    /// ⌃⌥↩: promote the focused satellite; on the primary seat, undo the last trade.
    case promote
    /// Overview / search / rail: put window `id` into the seat `into` names (nil = the primary seat).
    case pick(CGWindowID, into: SeatKey?)
    /// ⌃⌥L (+1) / ⌃⌥H (−1).
    case pass(Int)
    /// ⌃⌥K (+1) / ⌃⌥J (−1): move focus only.
    case look(Int)
    /// ⌃⌥P.
    case lock
    /// ⌃⌥1 / 2 / 3.
    case setCols(Int)
    case setEmphasis(Emphasis)
    /// ⌃⌥E.
    case toggleEmphasis
    /// ⌃⌥= / − : the focus window's share in 2-/3-up, the window's width in monocle.
    case adjustFocusRatio(CGFloat)
    /// ⌃⌥↑ / ↓.
    case adjustHeight(CGFloat)
    /// ⌃⌥] / [ : inner gap and outer padding together.
    case adjustGap(CGFloat)

    /// Commands a held key paces (at most one step per `Timing.navInterval`, latest wins).
    var isPaced: Bool {
        switch self {
        case .pass, .look: return true
        default: return false
        }
    }
}

/// Everything the reducer reacts to. One serial queue (main) feeds these in order, with the time
/// each one happened at (`Reducer.reduce(_:_:now:)`). Focus and input events join in commit 5.
public enum CoreEvent: Equatable {
    /// A command. `repeated` is true for an OS auto-repeat of a held key.
    case chord(Command, repeated: Bool)
    /// A fresh enumeration: every window that exists, **front to back**, with transient misses
    /// already resolved by the executor (an absent window is closed), and the window macOS has
    /// focused. Windows that appear, close, hide or come back are all found by diffing this
    /// snapshot (`Run.enumerated`); the observer's create / destroy / miniaturize notifications are
    /// triggers for it, not events of their own.
    case windowsEnumerated([WindowInfo], focused: CGWindowID?)
    /// A native tab switch: window `new` now shows the pane `old` showed.
    case tabReplaced(old: CGWindowID, new: WindowInfo)
    /// The strip display's visible frame or the display arrangement changed.
    case displayChanged(vis: CGRect, displays: [CGRect])
    /// The user finished moving (`wasResize` false) or resizing window `id`; `frame` is where they
    /// left it.
    case dragEnded(CGWindowID, wasResize: Bool, frame: CGRect)
    /// Window `id` settled at `actual` instead of `requested`, and still was after the executor's
    /// confirm read (`StripController.clampLearnConfirmDelay`): the app clamps its size.
    case frameClamped(CGWindowID, requested: CGRect, actual: CGRect)
    /// AX writes to window `id` keep failing (`WriteFailureTracker`): it's gone.
    case writeFailed(CGWindowID)
    /// The executor's one timer fired (see `SideEffect.wake`): run whatever is due.
    case tick
}

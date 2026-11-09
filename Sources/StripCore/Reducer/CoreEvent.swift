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
/// each one happened at (`Reducer.reduce(_:_:now:)`). Commit 3 has the command path; window, focus
/// and input events join in the next commits.
public enum CoreEvent: Equatable {
    /// A command. `repeated` is true for an OS auto-repeat of a held key.
    case chord(Command, repeated: Bool)
    /// The executor's one timer fired (see `SideEffect.wake`): run whatever is due.
    case tick
}

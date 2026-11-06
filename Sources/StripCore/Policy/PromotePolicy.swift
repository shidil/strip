import CoreGraphics
import Foundation

/// What the user did most recently, for attributing a focus change (Seats & Pile).
public enum UserInput: Equatable {
    /// A left mouseDown outside Strip: a click in a window, the Dock, a notification.
    case mouse
    /// A keyDown carrying ⌘: ⌘Tab, ⌘`, an app shortcut.
    case commandKey
}

/// Pure promote decisions, with time injected so every settle and grace window is unit-testable
/// (Seats & Pile slice 1). Automatic promotes stay behind the "Center on click or ⌘Tab" setting, off
/// by default until Spaces support lands (slice 5): today a Space round trip can re-admit every
/// window as new, which would set these off by mistake.
public enum PromotePolicy {
    /// How recent the user's own input must be for a focus change to count as theirs.
    public static let userCauseWindow: CFTimeInterval = 1.0
    /// Trailing settle before a ⌘-attributed focus change into a satellite promotes it, so a quick
    /// ⌘Tab through several apps promotes only the one you stop on.
    public static let commandKeySettle: TimeInterval = 0.25

    /// Who caused a focus change at `now`: the user's last input if it came within
    /// `userCauseWindow`, else nil (an app activated itself, `open -a`, AppleScript).
    public static func attribution(now: CFTimeInterval, lastInput: UserInput?,
                                   at lastInputAt: CFTimeInterval) -> UserInput? {
        guard let lastInput, now - lastInputAt <= userCauseWindow else { return nil }
        return lastInput
    }

    /// Whether external focus that just arrived in a visible satellite should promote it after the
    /// `commandKeySettle`. Only ⌘-attributed focus does: mouse-attributed focus waits for the
    /// committed-click detector instead, so a double-click or a drag in that window never promotes.
    public static func focusPromotes(enabled: Bool, attribution: UserInput?) -> Bool {
        enabled && attribution == .commandKey
    }

    /// Whether a committed click promotes the focused window `focused`, sitting in `slot`.
    ///
    /// The click must be what put focus there: either it landed on that very window
    /// (`clicked == focused`), or focus arrived in the window after the click's mouseDown (a Dock or
    /// notification click). A click on the menu bar or desktop while a satellite has focus does
    /// neither, so it never promotes. Never from the primary seat, a locked seat, or a parked window.
    public static func clickPromotes(enabled: Bool, focused: CGWindowID?, slot: Slot?, primary: Slot,
                                     locked: Bool, clicked: CGWindowID?,
                                     focusArrivedSinceMouseDown: Bool) -> Bool {
        guard enabled, let focused, let slot, slot != primary, !locked else { return false }
        return clicked == focused || focusArrivedSinceMouseDown
    }
}

/// Detects a **committed click**: a single click (clickCount 1) whose mouseUp lands within
/// `maxTravel` of its mouseDown, followed by no new mouseDown or scroll for the system's
/// double-click interval. A drag, a text selection or a double-click never commits. Pure; the
/// global mouse monitor feeds it and fires `commit(now:)` at the deadline `mouseUp` returns.
public struct ClickCommitTracker {
    /// Maximum pointer travel between mouseDown and mouseUp, in points.
    public static let maxTravel: CGFloat = 4

    private var downAt: CGPoint?
    private var pending: (point: CGPoint, deadline: CFTimeInterval)?

    public init() {}

    /// Whether a click is waiting out its double-click interval.
    public var isPending: Bool { pending != nil }

    /// A new mouseDown: any pending click turns out to be part of a double-click or a new gesture.
    public mutating func mouseDown(at point: CGPoint) {
        pending = nil
        downAt = point
    }

    /// The mouseUp. Returns the deadline (media time) at which the click commits if nothing else
    /// happens first, or nil when this wasn't a single, still click.
    public mutating func mouseUp(at point: CGPoint, clickCount: Int, now: CFTimeInterval,
                                 doubleClickInterval: CFTimeInterval) -> CFTimeInterval? {
        defer { downAt = nil }
        guard let down = downAt, clickCount == 1,
              hypot(point.x - down.x, point.y - down.y) < Self.maxTravel else {
            pending = nil
            return nil
        }
        let deadline = now + doubleClickInterval
        pending = (down, deadline)
        return deadline
    }

    /// A scroll, a Strip command, or anything else that means the click wasn't a commitment.
    public mutating func cancel() { pending = nil }

    /// At or after the deadline: the committed click's mouseDown point (Quartz global), once.
    public mutating func commit(now: CFTimeInterval) -> CGPoint? {
        guard let p = pending, now >= p.deadline - 0.001 else { return nil }
        pending = nil
        return p.point
    }
}

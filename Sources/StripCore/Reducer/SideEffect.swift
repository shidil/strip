import CoreGraphics
import Foundation

/// Something the executor does for the reducer, besides running the `MovePlan`.
public enum SideEffect: Equatable {
    /// Give keyboard focus to window `id` (AX focus + app activation). Already debounced: the
    /// reducer emits it once focus has rested for `Timing.focusSettle`.
    case focus(CGWindowID)
    /// Post `.tick` at media time `at`. The executor keeps one timer; each `wake` replaces it. A
    /// tick with nothing due is harmless.
    case wake(at: CFTimeInterval)
    /// Rebuild the overlay snapshot (rail, pill, focus ring) from the new state.
    case render
    /// Save the layout settings (`cols`, `emphasis`, `config`).
    case persist
    /// Window `id` is really at `at` (the user dragged it): restart its motion from there, with the
    /// snap-back spring, instead of from where the animator last left it.
    case reseed(CGWindowID, at: CGRect)
    /// Write a line to `/tmp/strip.log` (`LogLine.text(name:)` formats it).
    case log(LogLine)
    /// Enumerate every window (main thread) and send `CoreEvent.windowsEnumerated`.
    case enumerate
    /// Read macOS's focused window and send `CoreEvent.focusChanged`.
    case queryFocus
    /// Show a message in the overlay's pill (`Pill.text(name:)` formats it).
    case pill(Pill)
}

/// A message for the overlay's pill.
public enum Pill: Equatable {
    /// The user's focus is in a parked window that an app, not the user, focused.
    case parkedFocus(CGWindowID)

    public func text(name: (CGWindowID) -> String) -> String {
        switch self {
        case let .parkedFocus(id): return "Focus is in parked \(name(id)) — ⌃⌥I"
        }
    }
}

/// Which verb a trade log line names.
public enum TradeVerb: String, Equatable {
    case trade, promote, promoteUndo = "promote-undo", pick
}

/// What caused a trade, as the log line names it.
public enum TradeCause: Equatable {
    case tradeKey(SeatKey)
    case promoteKey
    case pick
    case click
    case commandKey

    public var label: String {
        switch self {
        case .tradeKey(let k): return "⌃⌥⇧\(k.rawValue.uppercased())"
        case .promoteKey: return "⌃⌥↩"
        case .pick: return "pick"
        case .click: return "click"
        case .commandKey: return "⌘ key"
        }
    }
}

/// A structured log line. Window names need the executor's app names, so the reducer emits ids
/// and `text(name:)` formats them. The texts match the strings the e2e scenarios grep for
/// (`scripts/e2e/scenarios.sh`); `LogLineTests` pins them.
public enum LogLine: Equatable {
    case draw(drawn: CGWindowID, displaced: CGWindowID?, seat: Slot)
    case drawEmpty(seat: Slot)
    case trade(TradeVerb, Trade, cut: Bool, cause: TradeCause)
    case tradeNoOp(focus: Slot, target: Slot)
    case promoteNoOp(undo: Bool)
    case pick(CGWindowID, seat: Slot, displaced: CGWindowID?)
    case pickNoOp(CGWindowID)
    case focusRatio(CGFloat)
    case monocleWidth(CGFloat)
    case height(CGFloat)
    case gap(inner: CGFloat, outer: CGFloat)
    case added(CGWindowID, seat: Slot?)
    case adopted(count: Int)
    case closed(CGWindowID, refill: CGWindowID?)
    case hidden(CGWindowID, refill: CGWindowID?)
    case restored(CGWindowID, seat: Slot?)
    case tabReplaced(old: CGWindowID, new: CGWindowID)
    case resizeKept(focusRatio: CGFloat, monocleWidth: CGFloat, height: CGFloat)
    case snappedBack(CGWindowID)
    case constraintLearned(CGWindowID, SizeConstraint)
    case constraintUnsatisfiable(cols: Int)
    case axDrop(CGWindowID)
    case focusFollow(CGWindowID, seat: Slot)
    case handOffCancelled(UserInput)
    case parkedFocus(CGWindowID)
    /// `into` is nil for the primary seat ("center").
    case summoned(CGWindowID, into: Slot?, displaced: CGWindowID?)
    case clickNotPromoted(CGWindowID, seat: Slot, locked: Bool)
    case clickToCenter(Bool)

    public func text(name: (CGWindowID) -> String) -> String {
        func two(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
        switch self {
        case let .draw(drawn, displaced, seat):
            let rest = displaced.map { " (\(name($0)) to the pile)" } ?? ""
            return "draw: \(name(drawn)) → \(seat.rawValue)\(rest)"
        case let .drawEmpty(seat):
            return "draw: nothing to draw into \(seat.rawValue) — the pile is empty"
        case let .trade(verb, t, cut, cause):
            return "\(verb.rawValue): \(name(t.a)) \(t.from.rawValue) → \(t.to.rawValue), "
                + "\(name(t.b)) \(t.to.rawValue) → \(t.from.rawValue) (\(cut ? "cut" : "spring")) ← \(cause.label)"
        case let .tradeNoOp(focus, target):
            return "trade: no-op (focus \(focus.rawValue), target \(target.rawValue))"
        case let .promoteNoOp(undo):
            return "promote: no-op (\(undo ? "no trade to undo" : "locked seat or monocle"))"
        case let .pick(id, seat, displaced):
            let rest = displaced.map { " (\(name($0)) to the pile)" } ?? ""
            return "pick: \(name(id)) → \(seat.rawValue)\(rest)"
        case let .pickNoOp(id):
            return "pick: no-op (\(name(id)))"
        case let .focusRatio(v):
            return "focus ratio: \(two(v))"
        case let .monocleWidth(v):
            return "monocle width: \(two(v))"
        case let .height(v):
            return "height: \(two(v))"
        case let .gap(inner, outer):
            return "gap: \(Int(inner)) pad: \(Int(outer))"
        case let .added(id, seat):
            return "new: \(name(id)) → \(seat.map(\.rawValue) ?? "the pile")"
        case let .adopted(count):
            return "adopt: \(count) window(s)"
        case let .closed(id, refill):
            return "close: \(name(id))" + (refill.map { " (refilled with \(name($0)))" } ?? "")
        case let .hidden(id, refill):
            return "hide: \(name(id))" + (refill.map { " (refilled with \(name($0)))" } ?? "")
        case let .restored(id, seat):
            return "restore: \(name(id)) → \(seat.map(\.rawValue) ?? "the pile")"
        case let .tabReplaced(old, new):
            return "tab: \(name(new)) replaces \(name(old))"
        case let .resizeKept(focusRatio, monocleWidth, height):
            return "user-resize kept: focusRatio \(two(focusRatio)), monocle \(two(monocleWidth)), height \(two(height))"
        case let .snappedBack(id):
            return "user-drag: window \(id) snapped back to slot"
        case let .constraintLearned(id, c):
            func f(_ v: CGFloat?) -> String { v.map { String(format: "%.0f", Double($0)) } ?? "-" }
            return "constraint-learned: \(name(id)) min=\(f(c.minWidth))x\(f(c.minHeight)) max=\(f(c.maxWidth))x\(f(c.maxHeight))"
        case let .constraintUnsatisfiable(cols):
            return "constraint-unsatisfiable: learned minimum sizes exceed the usable width in \(cols)-up — slotted windows spill off the display"
        case let .axDrop(id):
            return "ax-drop: window \(id) dead (AX writes failing) — dropped from strip"
        case let .focusFollow(id, seat):
            return "focus-follow: \(name(id)) → slot \(seat.rawValue)"
        case let .handOffCancelled(cause):
            return "focus hand-off cancelled ← \(cause == .mouse ? "mouseDown" : "⌘ key")"
        case let .parkedFocus(id):
            return "parked-focus: \(name(id)) focused without user input — left parked"
        case let .summoned(id, seat, displaced):
            return "summon: \(name(id)) → \(seat?.rawValue ?? "center")"
                + (displaced.map { " (swapped with \(name($0)))" } ?? "")
        case let .clickNotPromoted(id, seat, locked):
            return "click: committed in \(name(id)) (\(seat.rawValue)) — not promoted ("
                + (locked ? "locked seat" : "the click didn't land on it") + ")"
        case let .clickToCenter(on):
            return "click-to-center: \(on ? "on" : "off")"
        }
    }
}

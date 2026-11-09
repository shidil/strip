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
    /// Write a line to `/tmp/strip.log` (`LogLine.text(name:)` formats it).
    case log(LogLine)
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
        }
    }
}

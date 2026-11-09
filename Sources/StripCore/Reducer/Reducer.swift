import CoreGraphics
import Foundation

/// What one event did: the new state, the windows to move, and everything else to do.
public struct Reduction: Equatable {
    public var state: CoreState
    public var plan: MovePlan
    public var effects: [SideEffect]
}

/// The one reducer (`docs/design/seats-and-pile.md`, *Core architecture*; ADR-0006):
/// `reduce(state, event, now) -> (state, MovePlan, [SideEffect])`. Pure and deterministic: the same
/// state, event and time always give the same reduction, so a logged session replays as a test.
public enum Reducer {
    public static func reduce(_ state: CoreState, _ event: CoreEvent, now: CFTimeInterval) -> Reduction {
        var run = Run(state: state, now: now)
        switch event {
        case let .chord(command, repeated):
            run.chord(command, repeated: repeated)
        case .tick:
            run.tick()
        }
        if let next = run.state.pending.earliest, next != state.pending.earliest {
            run.effects.append(.wake(at: next))
        }
        return Reduction(state: run.state, plan: run.plan, effects: run.effects)
    }
}

/// One reduction in progress.
struct Run {
    var state: CoreState
    let now: CFTimeInterval
    var plan = MovePlan.none
    var effects: [SideEffect] = []

    init(state: CoreState, now: CFTimeInterval) {
        self.state = state
        self.now = now
    }

    // MARK: - Events

    mutating func chord(_ command: Command, repeated: Bool) {
        guard command.isPaced else {
            perform(command)
            return
        }
        if !repeated {
            // A fresh press acts now and supersedes a held key's queued step.
            state.pending.nav = nil
            state.pending.lastNavAt = now
            perform(command)
            return
        }
        let due = state.pending.lastNavAt + Timing.navInterval
        if state.pending.nav == nil, now >= due - Timing.slack {
            state.pending.lastNavAt = now
            perform(command)
        } else {
            state.pending.nav = Deadline(command, at: state.pending.nav?.at ?? due) // latest direction wins
        }
    }

    mutating func tick() {
        if let nav = state.pending.nav, nav.isDue(now) {
            state.pending.nav = nil
            state.pending.lastNavAt = now
            perform(nav.value)
        }
        if let handOff = state.pending.focusHandOff, handOff.isDue(now) {
            state.pending.focusHandOff = nil
            state.handedFocus = handOff.value
            effects.append(.focus(handOff.value))
        }
    }

    // MARK: - Commands

    mutating func perform(_ command: Command) {
        let before = state.table
        var t = before
        switch command {
        case let .draw(key):
            let seat = t.seat(for: key)
            let displaced = t.seats[seat], drawn = t.pile.first
            guard let drawn, t.draw(into: seat) else { return log(.drawEmpty(seat: seat)) }
            log(.draw(drawn: drawn, displaced: displaced, seat: seat))
            commit(t, from: before)

        case let .trade(key):
            let target = t.seat(for: key)
            guard t.trade(with: target), let trade = t.lastTrade else {
                return log(.tradeNoOp(focus: before.focusSeat, target: target))
            }
            log(.trade(.trade, trade, cut: cuts(trade, t), cause: .tradeKey(key)))
            commit(t, from: before)

        case .promote:
            let undo = t.focusSeat == t.primary
            guard t.promote(), let trade = t.lastTrade else { return log(.promoteNoOp(undo: undo)) }
            log(.trade(undo ? .promoteUndo : .promote, trade, cut: cuts(trade, t), cause: .promoteKey))
            commit(t, from: before)

        case let .pick(id, key):
            let seat = key.map(t.seat(for:)) ?? t.primary
            let fromSeat = t.seat(of: id), displaced = t.seats[seat]
            guard t.pick(id, into: seat) else { return log(.pickNoOp(id)) }
            if let fromSeat, fromSeat != seat, displaced != nil, let trade = t.lastTrade {
                log(.trade(.pick, trade, cut: cuts(trade, t), cause: .pick))
            } else if fromSeat != seat {
                log(.pick(id, seat: seat, displaced: fromSeat == nil ? displaced : nil))
            }
            commit(t, from: before)

        case let .pass(dir):
            let motion: CardMotion = t.passableSeats.count > 1 ? .slide : .cut // monocle: a draw toggle
            guard t.pass(dir) else { return }
            commit(t, from: before, motion: motion)

        case let .look(dir):
            guard t.look(dir) else { return }
            commit(t, from: before)

        case .lock:
            guard t.toggleLock() else { return }
            commit(t, from: before)

        case let .setCols(n):
            guard t.setCols(n) else { return }
            commit(t, from: before, persist: true)

        case let .setEmphasis(e):
            guard t.emphasis != e else { return }
            t.emphasis = e
            commit(t, from: before, persist: true)

        case .toggleEmphasis:
            t.emphasis = t.emphasis == .focus ? .equal : .focus
            commit(t, from: before, persist: true)

        case let .adjustFocusRatio(delta):
            if t.cols == 1 {
                t.config.monocleWidthFraction += delta
                t.config.monocleWidthFraction = t.config.clampedMonocleWidth
                log(.monocleWidth(t.config.monocleWidthFraction))
            } else {
                t.config.focusRatio += delta
                t.config.focusRatio = t.config.clampedFocusRatio
                log(.focusRatio(t.config.focusRatio))
            }
            commit(t, from: before, persist: true)

        case let .adjustHeight(delta):
            t.config.heightFraction += delta
            t.config.heightFraction = t.config.clampedHeight
            log(.height(t.config.heightFraction))
            commit(t, from: before, persist: true)

        case let .adjustGap(delta):
            t.config.innerGap = max(0, t.config.innerGap + delta)
            t.config.outerPadding = max(0, t.config.outerPadding + delta)
            log(.gap(inner: t.config.innerGap, outer: t.config.outerPadding))
            commit(t, from: before, persist: true)
        }
    }

    /// Whether a trade's two windows cut rather than spring (L↔R in 3-up).
    private func cuts(_ trade: Trade, _ t: Table) -> Bool {
        MotionPolicy.tradeCuts(trade.from, trade.to, cols: t.cols)
    }

    // MARK: - Applying a new table

    /// Adopt table `t`: plan the motion from `before`, move the park edges and the commanded
    /// frames along, schedule the focus hand-off, and ask for a render (and a save). A table equal
    /// to `before` changes nothing.
    mutating func commit(_ t: Table, from before: Table, motion: CardMotion = .cut, persist: Bool = false) {
        guard t != before else { return }
        let edgesAfter = Table.parkEdges(state.parkEdges, from: before, to: t)
        let next = MovePlan.build(from: before, to: t, on: state.stage, edgesBefore: state.parkEdges,
                                  edgesAfter: edgesAfter, motion: motion, current: state.lastTargets)
        plan = MovePlan(phases: plan.phases + next.phases)
        for step in next.steps { state.lastTargets[step.id] = step.frame }
        let members = Set(t.members)
        state.lastTargets = state.lastTargets.filter { members.contains($0.key) }
        state.parkEdges = edgesAfter
        state.table = t
        if t.focusedId != before.focusedId { scheduleFocusHandOff() }
        effects.append(.render)
        if persist { effects.append(.persist) }
    }

    /// The focused seat's window changed: hand it focus once it has rested there, unless it
    /// already has focus. Each change restarts the wait, so only the window you stop on gets
    /// activated; a change that doesn't touch the focused window (a lock, a satellite draw) leaves
    /// a pending hand-off alone.
    mutating func scheduleFocusHandOff() {
        guard let id = state.table.focusedId, id != state.handedFocus else {
            state.pending.focusHandOff = nil
            return
        }
        state.pending.focusHandOff = Deadline(id, at: now + Timing.focusSettle)
    }

    mutating func log(_ line: LogLine) {
        effects.append(.log(line))
    }
}

import CoreGraphics
import Foundation

extension Run {
    // MARK: - Focus

    /// macOS focus moved to window `id` (`docs/design/seats-and-pile.md`, *Interactions*: click a
    /// satellite, external focus into a visible satellite or a parked window).
    ///
    /// - Inside the grace after Strip's own activation of `pid`, it's Strip's own: ignored.
    /// - An unknown or unreadable window, or one the reducer thinks is hidden: re-enumerate.
    /// - While Strip's own hand-off is pending, macOS's focus is the window the user just moved
    ///   away from: ignored, and the hand-off wins (BUGS.md; a click or ⌘ key cancels the hand-off
    ///   before its own focus change arrives).
    /// - Into a seat: focus follows, moving nothing. With click-to-center on, ⌘-caused focus in an
    ///   unlocked satellite promotes it once it has rested there (`PromotePolicy.commandKeySettle`).
    /// - Into the pile: user-caused focus summons the window into a seat after
    ///   `Timing.parkedCoalesce` (latest wins), as a cut. App-caused focus moves nothing: the window
    ///   tops the pile, so ⌃⌥I draws it, and the pill says so.
    mutating func focusChanged(_ id: CGWindowID?, pid: Int32) {
        if isOwnActivation(pid) { return }
        guard let id, state.table.contains(id) else { return requestRescan() }
        guard state.pending.focusHandOff == nil else { return }
        let before = state.table
        guard before.hole(of: id) == nil, !before.hidden.contains(id) else { return requestRescan() }

        state.input.arrival = Stamp(id, at: now)
        state.handedFocus = id
        touchRecent(id)
        if state.pending.summon?.value != id { state.pending.summon = nil }
        if state.pending.promote?.value != id { state.pending.promote = nil }
        let who = PromotePolicy.attribution(now: now, lastInput: state.input.last, at: state.input.lastAt)
        var t = before

        if let seat = t.seat(of: id) {
            if t.focusSeat != seat {
                t.focusFollow(id)
                log(.focusFollow(id, seat: seat))
                commit(t, from: before)
            }
            if state.pending.promote == nil, promotable(id, in: t),
               PromotePolicy.focusPromotes(enabled: state.clickToCenter, attribution: who) {
                state.pending.promote = Deadline(id, at: now + PromotePolicy.commandKeySettle)
            }
        } else if who != nil {
            if state.pending.summon == nil { state.pending.summon = Deadline(id, at: now + Timing.parkedCoalesce) }
        } else {
            log(.parkedFocus(id))
            effects.append(.pill(.parkedFocus(id)))
            if let i = t.pile.firstIndex(of: id), i > 0 {
                t.pile.remove(at: i)
                t.pile.insert(id, at: 0)
                commit(t, from: before)
            }
        }
    }

    /// Whether a focus change for `pid` now is the one Strip's own hand-off caused: within
    /// `Timing.ownActivationGrace` of activating that app, with no click or ⌘ key since.
    private func isOwnActivation(_ pid: Int32) -> Bool {
        guard let own = state.input.ownActivation, own.value == pid, state.input.lastAt <= own.at else { return false }
        return now < own.at + Timing.ownActivationGrace
    }

    /// Whether window `id` sits in a satellite an automatic promote may take it from.
    private func promotable(_ id: CGWindowID, in t: Table) -> Bool {
        guard t.cols > 1, let s = t.seat(of: id) else { return false }
        return s != t.primary && !t.locks.contains(s)
    }

    /// Re-enumerate once the hints stop (trailing `Timing.rescanDebounce`).
    mutating func requestRescan() {
        state.pending.rescan = now + Timing.rescanDebounce
    }

    // MARK: - User input

    /// A click, scroll or ⌘ key outside Strip. A mouseDown or ⌘ key is the user's own input: it
    /// attributes the focus changes of the next second to them, drops a pending ⌘Tab promote, and
    /// cancels a pending hand-off (which would otherwise steal focus back after their click or
    /// switch). With click-to-center on, the mouse events feed the committed-click detector.
    mutating func userInput(_ input: InputEvent) {
        switch input {
        case let .mouseDown(point):
            noteInput(.mouse)
            state.input.lastMouseDownAt = now
            cancelClick()
            if state.clickToCenter { state.input.clicks.mouseDown(at: point) }
        case let .mouseUp(point, clickCount, hit, interval):
            guard state.clickToCenter else { return }
            let commitAt = state.input.clicks.mouseUp(at: point, clickCount: clickCount, now: now,
                                                      doubleClickInterval: interval)
            state.pending.click = commitAt.map { Deadline(hit, at: $0) }
        case .scroll:
            cancelClick()
        case .commandKey:
            noteInput(.commandKey)
        }
    }

    private mutating func noteInput(_ kind: UserInput) {
        state.input.last = kind
        state.input.lastAt = now
        state.pending.promote = nil
        guard state.pending.focusHandOff != nil else { return }
        state.pending.focusHandOff = nil
        log(.handOffCancelled(kind))
        state.pending.focusResync = now + Timing.focusResync
    }

    /// Drop a click waiting out its double-click interval.
    mutating func cancelClick() {
        state.input.clicks.cancel()
        state.pending.click = nil
    }

    // MARK: - Settings

    mutating func setting(_ setting: Setting) {
        switch setting {
        case let .clickToCenter(on):
            guard on != state.clickToCenter else { return }
            state.clickToCenter = on
            if !on {
                state.pending.promote = nil
                cancelClick()
            }
            log(.clickToCenter(on))
            effects.append(.persist)
        }
    }

    // MARK: - Deadlines

    /// Run the input and focus deadlines that are due (`tick`).
    mutating func fireInputDeadlines() {
        func due(_ at: CFTimeInterval?) -> Bool { at.map { now >= $0 - Timing.slack } ?? false }
        if due(state.pending.focusResync) {
            state.pending.focusResync = nil
            effects.append(.queryFocus)
        }
        if due(state.pending.rescan) {
            state.pending.rescan = nil
            effects.append(.enumerate)
        }
        if let s = state.pending.summon, s.isDue(now) {
            state.pending.summon = nil
            summonParked(s.value)
        }
        if let p = state.pending.promote, p.isDue(now) {
            state.pending.promote = nil
            autoPromote(p.value, cause: .commandKey)
        }
        if let c = state.pending.click, c.isDue(now) {
            state.pending.click = nil
            if state.input.clicks.commit(now: now) != nil { committedClick(hit: c.value) }
        }
    }

    /// The user focused parked window `id` and focus stayed there: draw it into the primary seat
    /// (or R, then L, past a lock) as a cut, and focus its seat. macOS already focused it, so
    /// nothing is activated.
    private mutating func summonParked(_ id: CGWindowID) {
        guard state.pending.focusHandOff == nil, state.handedFocus == id else { return }
        let before = state.table
        var t = before
        guard let seat = t.summon(id) else { return }
        t.focusFollow(id)
        log(.summoned(id, into: seat == t.primary ? nil : seat, displaced: before.seats[seat]))
        commit(t, from: before)
    }

    /// Promote window `id` from its satellite into the primary seat (a committed click, or ⌘ focus
    /// that rested), if focus is still there and Strip isn't handing it elsewhere.
    private mutating func autoPromote(_ id: CGWindowID, cause: TradeCause) {
        guard state.clickToCenter, state.pending.focusHandOff == nil, state.handedFocus == id else { return }
        let before = state.table
        var t = before
        guard t.promote(id), let trade = t.lastTrade else { return }
        log(.trade(.promote, trade, cut: cuts(trade, t), cause: cause))
        commit(t, from: before)
    }

    /// A click committed (`ClickCommitTracker`) on window `hit`. Promote the focused window when it
    /// sits in an unlocked satellite and the click put focus there: it landed on that window, or focus
    /// arrived in it after the mouseDown (a Dock or notification click). The focused window is the
    /// one the reducer tracked from `focusChanged`, not a fresh read.
    private mutating func committedClick(hit: CGWindowID?) {
        let t = state.table
        guard state.clickToCenter, t.cols > 1, state.pending.focusHandOff == nil,
              let id = state.handedFocus else { return }
        let seat = t.seat(of: id)
        let locked = seat.map { t.locks.contains($0) } ?? false
        let arrived = state.input.arrival.map { $0.value == id && $0.at >= state.input.lastMouseDownAt } ?? false
        guard PromotePolicy.clickPromotes(enabled: true, focused: id, slot: seat, primary: t.primary, locked: locked,
                                          clicked: hit, focusArrivedSinceMouseDown: arrived) else {
            if let seat, seat != t.primary { log(.clickNotPromoted(id, seat: seat, locked: locked)) }
            return
        }
        autoPromote(id, cause: .click)
    }
}

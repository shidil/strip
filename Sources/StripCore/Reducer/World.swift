import CoreGraphics
import Foundation

/// Whether a window can be seen.
public enum Visibility: String, Equatable {
    case shown
    /// In the Dock.
    case minimized
    /// Its app is hidden (⌘H).
    case hidden
}

/// What an enumeration reports about one window.
public struct WindowInfo: Equatable {
    public var id: CGWindowID
    public var pid: Int32
    /// Where the window is now (Quartz global).
    public var frame: CGRect
    public var visibility: Visibility
    /// Its app quantizes its size while resizing (terminals, `SteppingApps`): it moves in one write
    /// rather than a spring after a drag.
    public var steps: Bool

    public init(id: CGWindowID, pid: Int32 = 0, frame: CGRect, visibility: Visibility = .shown, steps: Bool = false) {
        self.id = id
        self.pid = pid
        self.frame = frame
        self.visibility = visibility
        self.steps = steps
    }
}

/// Which newly seen windows Strip manages. Only new windows are gated: a managed window stays
/// managed while it exists, wherever it is.
public enum Admission {
    /// A new window narrower or shorter than these fractions of the visible frame is a utility or
    /// transient window (a DMG installer, a palette) and floats (BUGS.md #4).
    public static let minWidthFraction: CGFloat = 0.2
    public static let minHeightFraction: CGFloat = 0.4

    public static func isTileable(_ size: CGSize, on vis: CGRect) -> Bool {
        size.width >= vis.width * minWidthFraction && size.height >= vis.height * minHeightFraction
    }

    /// Whether `frame` belongs to the strip: centered on the strip's display, or orphaned on no
    /// display at all (parked off-screen by a Strip that quit or crashed; reclaiming it means a
    /// restart never strands a window).
    public static func belongs(_ frame: CGRect, to stage: Stage) -> Bool {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        let center = CGPoint(x: stage.vis.midX, y: stage.vis.midY)
        let screens = stage.displays.isEmpty ? [stage.vis] : stage.displays
        let strip = screens.first { $0.contains(center) } ?? stage.vis
        return strip.contains(c) || !screens.contains { $0.contains(c) }
    }

    /// Whether a window Strip doesn't manage yet joins: shown, big enough, and on the strip.
    public static func admits(_ w: WindowInfo, on stage: Stage) -> Bool {
        w.visibility == .shown && isTileable(w.frame.size, on: stage.vis) && belongs(w.frame, to: stage)
    }
}

extension Run {
    // MARK: - Enumeration

    /// Diff a fresh enumeration against the table (`docs/design/seats-and-pile.md`, *Interactions*):
    ///
    /// 1. **Closed** (absent): a pile card is dropped; a face-up window's seat refills with the window
    ///    macOS just focused if it's in the pile, else `pile[0]` (`Table.remove`).
    /// 2. **Hidden / minimized**: a satellite becomes a hole; C becomes a hole and is refilled. **Back**:
    ///    the window retakes its seat, or is summoned from the pile (`Table.hide` / `restore`).
    /// 3. **New** (admitted): into an empty table, adoption by seat rect then front to back;
    ///    otherwise the focused one takes C (or R, then L, past a locked C) and the rest top the pile
    ///    front-most first, or go to its bottom with the "append" placement.
    ///
    /// macOS's focused window becomes the window Strip considers focused (and focus moves to its
    /// seat, moving nothing), so nothing re-activates it, unless Strip's own hand-off is pending.
    mutating func enumerated(_ list: [WindowInfo], focused: CGWindowID?) {
        let before = state.table
        var t = before
        var byId: [CGWindowID: WindowInfo] = [:]
        for w in list where byId[w.id] == nil { byId[w.id] = w }

        for id in before.members where byId[id] == nil {
            log(.closed(id, refill: t.remove(id, preferred: focused, recent: state.recent)))
        }

        for w in list where t.contains(w.id) {
            let wasShown = state.windows[w.id].map { $0.visibility == .shown } ?? (t.hole(of: w.id) == nil)
            if wasShown, w.visibility != .shown {
                log(.hidden(w.id, refill: t.hide(w.id, preferred: focused, recent: state.recent)))
            } else if !wasShown, w.visibility == .shown {
                log(.restored(w.id, seat: t.restore(w.id)))
            }
        }

        let fresh = list.filter { !t.contains($0.id) && Admission.admits($0, on: state.stage) }
        var moved: [CGWindowID: CGRect] = [:]
        for w in fresh { moved[w.id] = w.frame }
        if !fresh.isEmpty, t.members.isEmpty {
            t.adopt(fresh.map { ($0.id, $0.frame) }, focused: focused, on: state.stage)
            log(.adopted(count: fresh.count))
        } else if !fresh.isEmpty {
            let append = t.config.newWindowPlacement == .append
            let lead = append ? nil : fresh.first { $0.id == focused }
            let background = fresh.filter { $0.id != lead?.id }
            for w in (append ? background : background.reversed()) {
                log(.added(w.id, seat: t.add(w.id, focused: false, atBottom: append)))
            }
            if let lead { log(.added(lead.id, seat: t.add(lead.id, focused: true))) }
        }

        let members = Set(t.members)
        for (id, w) in byId where members.contains(id) { state.windows[id] = w }
        // macOS's focus is the truth, unless Strip's own hand-off is still pending (then the system
        // focus is the stale window the user just moved away from).
        if let focused, members.contains(focused), state.pending.focusHandOff == nil {
            state.handedFocus = focused
            touchRecent(focused)
            t.focusFollow(focused)
        }
        commit(t, from: before, moved: moved)
    }

    // MARK: - Native tabs

    /// Window `new.id` took over `old`'s place: its commanded frame, park edge, focus and recency
    /// carry over; the window is moved only if it isn't already where `old` was going.
    mutating func tabReplaced(_ old: CGWindowID, _ new: WindowInfo) {
        let before = state.table
        var t = before
        guard t.replace(old, with: new.id) else { return }
        log(.tabReplaced(old: old, new: new.id))
        if let target = state.lastTargets.removeValue(forKey: old) { state.lastTargets[new.id] = target }
        if let edge = state.parkEdges.removeValue(forKey: old) { state.parkEdges[new.id] = edge }
        if state.handedFocus == old { state.handedFocus = new.id }
        state.recent = state.recent.map { $0 == old ? new.id : $0 }
        state.windows[old] = nil
        state.windows[new.id] = new
        state.stage.constraints[old] = nil
        // Only the id changed, so plan from the renamed table itself: the new window moves only if
        // its real frame is off its seat (`moved`), and nothing else moves.
        state.table = t
        commit(t, from: t, moved: [new.id: new.frame])
    }

    // MARK: - Displays

    /// The display changed: re-lay every window out on the new geometry.
    mutating func displayChanged(vis: CGRect, displays: [CGRect]) {
        var next = state.stage
        next.vis = vis
        next.displays = displays
        guard next != state.stage else { return }
        let previous = state.stage
        state.stage = next
        commit(state.table, from: state.table, previous: previous)
    }

    // MARK: - User drags

    /// The user dragged window `id` (`StripController.handleUserDrag`'s policy). A **resize of the
    /// dominant window** (C in monocle and 3-up, the focused seat in 2-up) is kept: its new frame
    /// becomes the sizing knobs (`DragResolver`) and the row re-proportions around it. Any other move
    /// or resize **snaps back** to the seat, starting from where the user let go. Windows whose app
    /// steps its size move in one write.
    mutating func dragEnded(_ id: CGWindowID, wasResize: Bool, frame: CGRect) {
        var t = state.table
        guard t.contains(id), t.hole(of: id) == nil else { return }
        let dominant = t.seats[t.cols == 2 ? t.focusSeat : .C]
        var persist = false
        if wasResize, id == dominant {
            t.config = DragResolver.resizeConfig(focusFrame: frame, vis: state.stage.vis, cols: t.cols,
                                                 emphasis: t.emphasis, base: t.config)
            log(.resizeKept(focusRatio: t.config.focusRatio, monocleWidth: t.config.monocleWidthFraction,
                            height: t.config.heightFraction))
            persist = true
        } else {
            log(.snappedBack(id))
        }
        effects.append(.reseed(id, at: frame))
        commit(t, from: state.table, moved: [id: frame], steppingCuts: true, persist: persist)
    }

    // MARK: - Size clamps

    /// Window `id` holds a size the app chose over the one Strip asked for. Ignored when the
    /// reducer has since asked for something else (the clamp says nothing about the new target).
    /// A clamp that teaches a new bound (`SizeConstraint.learned`: ≥ 8 pt, per dimension,
    /// monotonic, floors capped at the display) re-lays the row out around it, once; the re-layout
    /// targets sizes inside the bounds, so it can't clamp again. A clamp that teaches nothing
    /// changes nothing.
    mutating func frameClamped(_ id: CGWindowID, requested: CGRect, actual: CGRect) {
        guard state.table.contains(id), let commanded = state.lastTargets[id] ?? state.table
            .targets(on: state.stage, parkEdges: state.parkEdges)[id],
            MovePlan.matches(commanded, requested),
            let learned = SizeConstraint.learned(from: state.stage.constraints[id], requested: requested.size,
                                                 actual: actual.size, bounds: state.stage.vis.size)
        else { return }
        let previous = state.stage
        state.stage.constraints[id] = learned
        log(.constraintLearned(id, learned))
        commit(state.table, from: state.table, previous: previous, moved: [id: actual])
    }

    // MARK: - Lost windows

    /// Writes to window `id` keep failing: it's gone (an app relaunched or crashed). Drop it as if
    /// it closed, so it stops holding a seat.
    mutating func writeFailed(_ id: CGWindowID) {
        let before = state.table
        guard before.contains(id) else { return }
        var t = before
        log(.axDrop(id))
        log(.closed(id, refill: t.remove(id, recent: state.recent)))
        commit(t, from: before)
    }
}

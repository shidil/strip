import CoreGraphics

/// How one step moves its window.
public enum MoveKind: Equatable {
    /// Glide there (the animator's springs).
    case spring
    /// One instant write that is part of a content change the user sees: a card entering or
    /// leaving a seat, or an L↔R trade.
    case cut
    /// One instant write the user doesn't see: a parked card resized or moved to another edge, or a
    /// card pre-sized before it's placed.
    case snap
}

/// One window's move in a plan.
public struct MoveStep: Equatable {
    public let id: CGWindowID
    public let frame: CGRect
    public let kind: MoveKind

    public init(id: CGWindowID, frame: CGRect, kind: MoveKind) {
        self.id = id
        self.frame = frame
        self.kind = kind
    }
}

/// The ordered moves that take the windows from one table to the next
/// (`docs/design/seats-and-pile.md`, *Core architecture*). Phases run in order with a barrier
/// between them: the executor starts phase N+1 only after every write of phase N has landed (step
/// 3 teaches the animator per-pid completion barriers). Within a phase, steps are ordered by id.
///
/// A plan has at most three phases:
/// 1. **Prepare** — invisible snaps: parked cards that change edge or size, an incoming card
///    pre-sized while still parked, a sliding card moved to the edge it enters from.
/// 2. **Show** — springs, and cuts that put a window on screen (a drawn card, a new window, an
///    L↔R trade).
/// 3. **Clear** — cuts that take a window off screen (the displaced card parks), only after its
///    replacement is placed, so no frame shows wallpaper.
///
/// Empty phases are dropped. A window appears in at most two steps (prepare, then show).
public struct MovePlan: Equatable {
    public var phases: [[MoveStep]]

    public init(phases: [[MoveStep]]) {
        self.phases = phases.filter { !$0.isEmpty }
    }

    public static let none = MovePlan(phases: [])

    public var isEmpty: Bool { phases.isEmpty }
    /// Every step, in execution order.
    public var steps: [MoveStep] { phases.flatMap { $0 } }
    /// The windows the plan writes to.
    public var ids: Set<CGWindowID> { Set(steps.map(\.id)) }

    public func steps(_ kind: MoveKind) -> [MoveStep] { steps.filter { $0.kind == kind } }

    /// The plan from table `from` to table `to` on `stage`.
    ///
    /// `current` is each window's frame now (the reducer passes what it last commanded); a window
    /// missing from it is assumed to be at its target on `from`. A window whose `current` frame is
    /// off its unchanged target (the user dragged it, a tab switch showed a new window) is moved
    /// back: a spring to a seat, a snap to a park. `previous` is the stage `from` was laid out on
    /// when the geometry changed (`transitions`). `edgesBefore` / `edgesAfter` are the pile's park
    /// edges on each table (`Table.parkEdges`); `motion` is how cards enter and leave. A spring that
    /// would sweep across the display (`MotionPolicy.sweepsAcross`) becomes a cut.
    public static func build(from: Table, to: Table, on stage: Stage, previous: Stage? = nil,
                             edgesBefore: [CGWindowID: Edge] = [:], edgesAfter: [CGWindowID: Edge] = [:],
                             motion: CardMotion = .cut,
                             current: [CGWindowID: CGRect] = [:]) -> MovePlan {
        var kinds = transitions(from: from, to: to, on: stage, previous: previous, edgesBefore: edgesBefore,
                                edgesAfter: edgesAfter, motion: motion)
        let was = from.targets(on: previous ?? stage, parkEdges: edgesBefore)
        let targets = to.targets(on: stage, parkEdges: edgesAfter)
        let vis = stage.vis
        let screens = stage.displays.isEmpty ? [vis] : stage.displays
        func onScreen(_ r: CGRect) -> Bool { screens.contains { r.intersects($0) } }

        for (id, kind) in kinds where kind == .stay {
            if let now = current[id], let target = targets[id], !Self.matches(now, target) {
                kinds[id] = onScreen(target) ? .spring : .snapOffscreen
            }
        }

        var prepare: [MoveStep] = [], show: [MoveStep] = [], clear: [MoveStep] = []
        for id in kinds.keys.sorted() {
            guard let kind = kinds[id], kind != .stay, let target = targets[id] else { continue }
            let now = current[id] ?? was[id]
            if let now, Self.matches(now, target) { continue } // already there: no write
            switch kind {
            case .stay:
                continue
            case .snapOffscreen:
                prepare.append(MoveStep(id: id, frame: target, kind: .snap))
            case .spring:
                if case .pile? = Spot(id, on: from), let seat = to.seat(of: id) {
                    // Slide in from the edge nearest the seat, pre-sized to it.
                    let entry = to.parkFrame(for: id, edge: Edge.nearest(to: seat), on: stage, size: target.size)
                    if now != entry { prepare.append(MoveStep(id: id, frame: entry, kind: .snap)) }
                    show.append(MoveStep(id: id, frame: target, kind: .spring))
                } else if let now, MotionPolicy.sweepsAcross(from: now, to: target, in: vis, displays: stage.displays) {
                    let step = MoveStep(id: id, frame: target, kind: .cut)
                    if onScreen(target) { show.append(step) } else { clear.append(step) }
                } else {
                    show.append(MoveStep(id: id, frame: target, kind: .spring))
                }
            case .cut:
                guard onScreen(target) else {
                    clear.append(MoveStep(id: id, frame: target, kind: .cut))
                    continue
                }
                if let now, !onScreen(now), now.size != target.size {
                    prepare.append(MoveStep(id: id, frame: resizedInPlace(now, to: target.size, vis: vis), kind: .snap))
                }
                show.append(MoveStep(id: id, frame: target, kind: .cut))
            }
        }
        return MovePlan(phases: [prepare, show, clear])
    }

    /// Whether two frames are the same within the animator's settle tolerance (1.5 pt per edge;
    /// `WindowAnimator.frameMatches`).
    public static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1.5) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// A parked frame resized to `size` without leaving its park: anchored on the side that faces
    /// the display, so growing never pushes it onto the screen.
    static func resizedInPlace(_ r: CGRect, to size: CGSize, vis: CGRect) -> CGRect {
        let x = r.midX < vis.midX ? r.maxX - size.width : r.minX
        return CGRect(x: x, y: r.midY - size.height / 2, width: size.width, height: size.height)
    }
}

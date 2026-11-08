import CoreGraphics

/// The display a Table is laid out on. All rects are Quartz global (top-left origin, Y down).
public struct Stage: Equatable {
    /// The strip display's visible frame.
    public var vis: CGRect
    /// Every display's frame, the strip display's included. Empty means just `vis`.
    public var displays: [CGRect]
    /// Each window's learned real-size bounds (`SizeConstraint`).
    public var constraints: [CGWindowID: SizeConstraint]

    public init(vis: CGRect, displays: [CGRect] = [], constraints: [CGWindowID: SizeConstraint] = [:]) {
        self.vis = vis
        self.displays = displays
        self.constraints = constraints
    }

    /// Gap between a parked window and the display edge. Same as the ring's
    /// (`StripLayout.parkGap`); whether it leaves a visible sliver is decided in step 3.
    public static let parkGap: CGFloat = 40

    /// Displays other than the strip display: a park frame must not land on one.
    var neighbors: [CGRect] {
        displays.filter { !$0.contains(CGPoint(x: vis.midX, y: vis.midY)) }
    }
}

/// The display edge a pile card parks off.
public enum Edge: String, Equatable, Codable {
    case left, right

    public var opposite: Edge { self == .left ? .right : .left }

    /// The edge nearest a seat: a card leaving L parks left; one leaving C or R parks right.
    public static func nearest(to seat: Slot) -> Edge {
        seat == .L ? .left : .right
    }
}

public extension Table {
    /// The on-screen rect of each seat. Seats are sized around the learned bounds of the windows
    /// they hold (`SlotGeometry`'s constraint solve).
    func seatRects(on stage: Stage) -> [Slot: CGRect] {
        var requirements: [Slot: SizeConstraint] = [:]
        for (s, id) in seats {
            if let c = stage.constraints[id] { requirements[s] = c }
        }
        return SlotGeometry.rects(cols: cols, emphasis: emphasis, focusSlot: focusSeat, in: stage.vis,
                                  config: config, requirements: requirements)
    }

    /// Where pile card `id` rests: fully off `edge`, vertically centered on the display. Sized like
    /// the seat at that end of the row (laid out with focus on the primary seat, so a 2-up focus
    /// change doesn't resize every parked card), clamped to the window's learned bounds; `size`
    /// overrides that. If a neighboring display sits off `edge`, the card parks off the other edge.
    func parkFrame(for id: CGWindowID, edge: Edge, on stage: Stage, size: CGSize? = nil) -> CGRect {
        let vis = stage.vis
        let sz = size ?? parkSize(for: id, edge: edge, on: stage)
        func frame(_ e: Edge) -> CGRect {
            let x = e == .left ? vis.minX - sz.width - Stage.parkGap : vis.maxX + Stage.parkGap
            return CGRect(x: x, y: vis.midY - sz.height / 2, width: sz.width, height: sz.height)
        }
        let neighbors = stage.neighbors
        let preferred = frame(edge)
        guard neighbors.contains(where: { preferred.intersects($0) }) else { return preferred }
        let other = frame(edge.opposite)
        return neighbors.contains(where: { other.intersects($0) }) ? preferred : other
    }

    /// The resting size of pile card `id` parked off `edge`.
    func parkSize(for id: CGWindowID, edge: Edge, on stage: Stage) -> CGSize {
        let rects = SlotGeometry.rects(cols: cols, emphasis: emphasis, focusSlot: primary, in: stage.vis,
                                       config: config)
        let end = edge == .left ? slots.first : slots.last
        var size = end.flatMap { rects[$0] }?.size
            ?? CGSize(width: stage.vis.width * 0.2, height: stage.vis.height * 0.6)
        if let c = stage.constraints[id] { size = c.clamped(size) }
        return size
    }

    /// Where every window should be: seated windows in their seat rects, pile cards parked off the
    /// edge in `parkEdges` (right when unlisted). Hidden windows (holes) have no target: Strip never
    /// moves a hidden window.
    func targets(on stage: Stage, parkEdges: [CGWindowID: Edge]) -> [CGWindowID: CGRect] {
        let rects = seatRects(on: stage)
        var out: [CGWindowID: CGRect] = [:]
        for (s, id) in seats {
            if let r = rects[s] { out[id] = r }
        }
        for id in pile {
            out[id] = parkFrame(for: id, edge: parkEdges[id] ?? .right, on: stage)
        }
        return out
    }

    /// The park edges after a change from `before` to `after`: a card that just left a seat parks
    /// off the edge nearest that seat; every other pile card keeps its edge (right when unknown).
    /// Only pile cards are listed.
    static func parkEdges(_ edges: [CGWindowID: Edge], from before: Table, to after: Table) -> [CGWindowID: Edge] {
        var out: [CGWindowID: Edge] = [:]
        for id in after.pile {
            out[id] = before.seat(of: id).map(Edge.nearest(to:)) ?? edges[id] ?? .right
        }
        return out
    }
}

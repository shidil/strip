import CoreGraphics

/// Tuning for a critically-/under-damped spring. Presets are cycled by the `t` key in M5.
public struct SpringConfig {
    public var stiffness: Double
    public var damping: Double
    public var name: String

    public init(stiffness: Double, damping: Double, name: String) {
        self.stiffness = stiffness
        self.damping = damping
        self.name = name
    }

    /// Critically-damped spring (no overshoot) of a given stiffness.
    public static func critical(_ stiffness: Double, name: String) -> SpringConfig {
        SpringConfig(stiffness: stiffness, damping: 2 * (stiffness).squareRoot(), name: name)
    }

    /// Default "film slide" feel — smooth, slightly snappy, no overshoot.
    public static let track = SpringConfig.critical(220, name: "Track")
    /// A bouncier underdamped preset.
    public static let pop = SpringConfig(stiffness: 320, damping: 22, name: "Pop")
    /// Gentle, slow dissolve-like glide.
    public static let glide = SpringConfig.critical(110, name: "Glide")

    public static let presets: [SpringConfig] = [.track, .pop, .glide]

    /// Crisp, fast, no-overshoot return used for snapping a hand-dragged window back to its slot
    /// (M7). Not in `presets` — it overrides the user's film-slide feel only for that one motion, so
    /// the snap-back lands quickly instead of drifting under a soft/bouncy preset.
    public static let snapBack = SpringConfig.critical(340, name: "SnapBack")
}

/// A single scalar driven toward a target by a spring (semi-implicit Euler integration).
struct SpringScalar {
    var value: Double
    var velocity: Double = 0

    mutating func step(to target: Double, dt: Double, _ cfg: SpringConfig) {
        let accel = cfg.stiffness * (target - value) - cfg.damping * velocity
        velocity += accel * dt
        value += velocity * dt
    }

    /// Settled when both displacement and speed are below sub-pixel thresholds.
    func settled(near target: Double) -> Bool {
        abs(target - value) < 0.5 && abs(velocity) < 0.5
    }
}

/// A spring over a full rect (origin + size animate independently).
struct RectSpring {
    var x: SpringScalar, y: SpringScalar, w: SpringScalar, h: SpringScalar

    init(_ frame: CGRect) {
        x = SpringScalar(value: frame.origin.x)
        y = SpringScalar(value: frame.origin.y)
        w = SpringScalar(value: frame.size.width)
        h = SpringScalar(value: frame.size.height)
    }

    var current: CGRect {
        CGRect(x: x.value, y: y.value, width: max(1, w.value), height: max(1, h.value))
    }

    mutating func step(to target: CGRect, dt: Double, _ cfg: SpringConfig) {
        x.step(to: target.origin.x, dt: dt, cfg)
        y.step(to: target.origin.y, dt: dt, cfg)
        w.step(to: target.size.width, dt: dt, cfg)
        h.step(to: target.size.height, dt: dt, cfg)
    }

    func settled(near t: CGRect) -> Bool {
        x.settled(near: t.origin.x) && y.settled(near: t.origin.y)
            && w.settled(near: t.size.width) && h.settled(near: t.size.height)
    }
}

import Foundation

/// Which screen edge the film rail (minimap) is anchored to. `.top`/`.bottom` keep the rail's
/// horizontal chip-row layout; `.left`/`.right` switch it to a vertical stack (see `FilmRailView`).
public enum RailEdge: String, Codable, CaseIterable {
    case bottom, top, left, right
    public static let `default` = RailEdge.bottom
    public var isVertical: Bool { self == .left || self == .right }
}

/// The subset of strip state that should survive a restart: the sizing knobs (`LayoutConfig`) and the
/// layout posture (column count, emphasis, spring preset). Window identity — the ring, center, and
/// pins — is deliberately **excluded**: `CGWindowID`s aren't stable across a relaunch, so they're
/// re-discovered fresh each launch (`StripController.refresh()`).
///
/// Persisted as JSON in `UserDefaults` under the app's domain (`io.github.shidil.strip`).
struct PersistedSettings: Codable, Equatable {
    var config: LayoutConfig
    var cols: Int
    var emphasisEqual: Bool
    var springIndex: Int
    /// Whether the focus ring (the border drawn around the focused window) is shown. Toggled from the
    /// status-bar menu. Declared last with a default so older blobs (and the existing call sites that
    /// omit it) keep working via the memberwise init.
    var focusRingEnabled: Bool = true
    /// Which screen edge the film rail is anchored to. Declared last with a default for the same
    /// forward-compatibility reason as `focusRingEnabled`.
    var railEdge: RailEdge = .default

    private static let key = "strip.settings.v1"

    init(config: LayoutConfig, cols: Int, emphasisEqual: Bool, springIndex: Int,
         focusRingEnabled: Bool = true, railEdge: RailEdge = .default) {
        self.config = config
        self.cols = cols
        self.emphasisEqual = emphasisEqual
        self.springIndex = springIndex
        self.focusRingEnabled = focusRingEnabled
        self.railEdge = railEdge
    }

    /// Decode tolerantly so a blob written before `focusRingEnabled`/`railEdge` existed still loads —
    /// missing fields fall back to their defaults rather than failing the whole decode (which would
    /// silently wipe a user's settings). Mirrors `LayoutConfig`'s forward-compatible decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decodeIfPresent(LayoutConfig.self, forKey: .config) ?? .default
        cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 3
        emphasisEqual = try c.decodeIfPresent(Bool.self, forKey: .emphasisEqual) ?? false
        springIndex = try c.decodeIfPresent(Int.self, forKey: .springIndex) ?? 0
        focusRingEnabled = try c.decodeIfPresent(Bool.self, forKey: .focusRingEnabled) ?? true
        railEdge = try c.decodeIfPresent(RailEdge.self, forKey: .railEdge) ?? .default
    }

    /// Load the saved settings, or nil if none have been written yet (or decoding fails).
    static func load(from defaults: UserDefaults = .standard) -> PersistedSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedSettings.self, from: data)
    }

    /// Persist these settings. Failures are silently ignored — losing a tuning preference is harmless.
    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

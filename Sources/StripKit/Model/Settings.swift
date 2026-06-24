import Foundation

/// The subset of strip state that should survive a restart: the sizing knobs (`LayoutConfig`) and the
/// layout posture (column count, emphasis, spring preset). Window identity — the ring, center, and
/// pins — is deliberately **excluded**: `CGWindowID`s aren't stable across a relaunch, so they're
/// re-discovered fresh each launch (`StripController.refresh()`).
///
/// Persisted as JSON in `UserDefaults` under the app's domain (`com.spike.strip`).
struct PersistedSettings: Codable, Equatable {
    var config: LayoutConfig
    var cols: Int
    var emphasisEqual: Bool
    var springIndex: Int

    private static let key = "strip.settings.v1"

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

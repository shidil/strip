import XCTest
@testable import StripKit

/// `PersistedSettings` is what survives a relaunch — verify it round-trips through its Codable form
/// (the encode/decode path used by save/load) without losing any tuned value.
final class SettingsTests: XCTestCase {
    func testSettingsRoundTripThroughCodable() throws {
        let original = PersistedSettings(
            config: LayoutConfig(outerPadding: 12, innerGap: 6, focusRatio: 0.62,
                                  monocleWidthFraction: 0.55, heightFraction: 0.8),
            cols: 2, emphasisEqual: true, springIndex: 2)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSaveThenLoadRestoresValues() {
        // Use an isolated UserDefaults suite so the test never touches the app's real settings.
        let defaults = UserDefaults(suiteName: "strip.tests.\(UUID().uuidString)")!
        let settings = PersistedSettings(
            config: LayoutConfig(focusRatio: 0.7, heightFraction: 0.65),
            cols: 1, emphasisEqual: false, springIndex: 1)
        settings.save(to: defaults)
        XCTAssertEqual(PersistedSettings.load(from: defaults), settings)
    }

    func testLoadReturnsNilWhenNothingSaved() {
        let defaults = UserDefaults(suiteName: "strip.tests.empty.\(UUID().uuidString)")!
        XCTAssertNil(PersistedSettings.load(from: defaults))
    }
}

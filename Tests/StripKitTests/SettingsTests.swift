import XCTest
@testable import StripKit

/// `PersistedSettings` is what survives a relaunch — verify it round-trips through its Codable form
/// (the encode/decode path used by save/load) without losing any tuned value.
final class SettingsTests: XCTestCase {
    func testSettingsRoundTripThroughCodable() throws {
        let original = PersistedSettings(
            config: LayoutConfig(outerPadding: 12, innerGap: 6, focusRatio: 0.62,
                                  monocleWidthFraction: 0.55, heightFraction: 0.8),
            cols: 2, emphasisEqual: true, springIndex: 2, focusRingEnabled: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.focusRingEnabled)
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

    /// A blob written before `newWindowPlacement` existed must still decode — the missing knob falls
    /// back to its default rather than failing the whole decode (which would silently wipe settings).
    func testLayoutConfigDecodesOlderBlobWithoutNewWindowPlacement() throws {
        let legacy = """
        {"outerPadding":10,"innerGap":6,"focusRatio":0.62,"monocleWidthFraction":0.55,"heightFraction":0.8}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(LayoutConfig.self, from: legacy)
        XCTAssertEqual(config.focusRatio, 0.62, accuracy: 0.0001)
        XCTAssertEqual(config.newWindowPlacement, .focusCenter, "missing knob defaults, decode succeeds")
    }

    /// A blob written before `focusRingEnabled` existed must still decode — the missing flag defaults
    /// to `true` (ring on) rather than failing the whole decode and wiping settings.
    func testSettingsDecodesOlderBlobWithoutFocusRingFlag() throws {
        let legacy = """
        {"config":{"outerPadding":8,"innerGap":8,"focusRatio":0.5,"monocleWidthFraction":0.6,"heightFraction":1.0,"newWindowPlacement":"focusCenter"},"cols":3,"emphasisEqual":false,"springIndex":0}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(PersistedSettings.self, from: legacy)
        XCTAssertEqual(settings.cols, 3)
        XCTAssertTrue(settings.focusRingEnabled, "missing flag defaults to ring-on, decode succeeds")
    }

    /// A blob written before `railEdge` existed (the minimap-polish addition) must still decode —
    /// mirrors the `focusRingEnabled` forward-compatibility test above.
    func testSettingsDecodesOlderBlobWithoutRailEdge() throws {
        let legacy = """
        {"config":{"outerPadding":8,"innerGap":8,"focusRatio":0.5,"monocleWidthFraction":0.6,"heightFraction":1.0,"newWindowPlacement":"focusCenter"},"cols":3,"emphasisEqual":false,"springIndex":0,"focusRingEnabled":true}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(PersistedSettings.self, from: legacy)
        XCTAssertEqual(settings.railEdge, .bottom, "missing edge defaults to .bottom, decode succeeds")
    }

    func testRailEdgeRoundTripsThroughSettings() throws {
        let original = PersistedSettings(
            config: .default, cols: 3, emphasisEqual: false, springIndex: 0, railEdge: .left)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: data)
        XCTAssertEqual(decoded.railEdge, .left)
    }
}

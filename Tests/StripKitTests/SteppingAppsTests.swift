import XCTest
@testable import StripKit

/// Terminal-class apps re-quantize their size every frame, so a resize-keep snaps them instead of
/// springing (M7). These pin which apps that covers.
final class SteppingAppsTests: XCTestCase {
    func testKnownTerminalBundleIdsStep() {
        XCTAssertTrue(SteppingApps.isStepping(key: "com.apple.Terminal", appName: "Terminal"))
        XCTAssertTrue(SteppingApps.isStepping(key: "com.googlecode.iterm2", appName: "iTerm2"))
        XCTAssertTrue(SteppingApps.isStepping(key: "com.mitchellh.ghostty", appName: "Ghostty"))
    }

    func testUnknownTerminalMatchesByName() {
        // cmux has no known bundle id — caught by the name heuristic.
        XCTAssertTrue(SteppingApps.isStepping(key: "com.example.cmux", appName: "cmux"))
        XCTAssertTrue(SteppingApps.isStepping(key: "WezTerm", appName: "WezTerm"))
    }

    func testPerPixelAppsDoNotStep() {
        XCTAssertFalse(SteppingApps.isStepping(key: "org.mozilla.firefox", appName: "Firefox"))
        XCTAssertFalse(SteppingApps.isStepping(key: "com.apple.Safari", appName: "Safari"))
        XCTAssertFalse(SteppingApps.isStepping(key: "com.tinyspeck.slackmacgap", appName: "Slack"))
    }
}

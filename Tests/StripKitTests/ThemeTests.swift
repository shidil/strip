import XCTest
@testable import StripKit

final class ThemeTests: XCTestCase {
    func testStableHashIsDeterministic() {
        XCTAssertEqual(Theme.stableHash("com.apple.Safari"), Theme.stableHash("com.apple.Safari"))
    }

    func testAccentIsStableForKey() {
        let a = Theme.accent(for: "com.apple.Terminal")
        let b = Theme.accent(for: "com.apple.Terminal")
        XCTAssertEqual(a, b)
    }

    func testLetterIsFirstCharUppercased() {
        XCTAssertEqual(Theme.letter(for: "Safari"), "S")
        XCTAssertEqual(Theme.letter(for: "terminal"), "T")
        XCTAssertEqual(Theme.letter(for: ""), "•")
    }
}

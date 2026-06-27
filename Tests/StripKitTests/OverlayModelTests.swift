import AppKit
import XCTest
@testable import StripKit

/// Pure tests for the overlay model's change-detection logic — the part of the incremental-render
/// path (stable SwiftUI roots + `@Published` mutation) that can be tested without AppKit views.
final class OverlayModelTests: XCTestCase {
    private func item(id: CGWindowID = 1, letter: String = "A", accent: NSColor = .red,
                      assigned: Bool = true, active: Bool = false, pinned: Bool = false) -> RailItem {
        RailItem(id: id, letter: letter, appName: "App", title: "Title", accent: accent,
                 assigned: assigned, active: active, pinned: pinned, aspect: 1.6)
    }

    func testRailItemEqualWhenAllFieldsMatch() {
        XCTAssertEqual(item(), item())
    }

    func testRailItemActiveFlagDifferenceIsUnequal() {
        // The whole point of the skip-filter: a moving highlight must register as a change.
        XCTAssertNotEqual(item(active: false), item(active: true))
    }

    func testRailItemAccentComparedByValueNotIdentity() {
        // NSColor is a class; equality must use isEqual, so two distinct-but-equal colors match…
        XCTAssertEqual(item(accent: NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)),
                       item(accent: NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)))
        // …and different colors differ.
        XCTAssertNotEqual(item(accent: .red), item(accent: .blue))
    }

    func testStatusFieldsEquality() {
        let a = StatusFields(activeApp: "Ghostty", layoutLabel: "3‑up · focus",
                             modeLabel: "Strip shift", transLabel: "Track", clock: "9:41")
        let same = StatusFields(activeApp: "Ghostty", layoutLabel: "3‑up · focus",
                                modeLabel: "Strip shift", transLabel: "Track", clock: "9:41")
        let diff = StatusFields(activeApp: "Slack", layoutLabel: "3‑up · focus",
                                modeLabel: "Strip shift", transLabel: "Track", clock: "9:41")
        XCTAssertEqual(a, same)
        XCTAssertNotEqual(a, diff)
    }

    func testRailNeedsRefitOnlyOnCountChange() {
        XCTAssertFalse(railNeedsRefit(oldCount: 3, newCount: 3)) // slide: count unchanged → no refit
        XCTAssertTrue(railNeedsRefit(oldCount: 3, newCount: 4))  // window opened
        XCTAssertTrue(railNeedsRefit(oldCount: 3, newCount: 2))  // window closed
        XCTAssertTrue(railNeedsRefit(oldCount: -1, newCount: 0)) // first render from sentinel
    }
}

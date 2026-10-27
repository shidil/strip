import AppKit
import XCTest
@testable import StripKit

final class SearchModelTests: XCTestCase {
    private func rail(_ titles: [(CGWindowID, String)]) -> [RailItem] {
        titles.map { id, title in
            RailItem(id: id, letter: "F", appName: "Firefox", title: title, accent: .gray, icon: nil,
                     assigned: true, active: false, pinned: false, aspect: 1.6)
        }
    }

    private func tab(_ id: CGWindowID, _ title: String, selected: Bool, index: Int = 0) -> WindowTab {
        let el = AXUIElementCreateApplication(getpid())
        return WindowTab(windowID: id, title: title, selected: selected, separateWindow: false,
                         index: index, window: AXWindow(element: el, pid: getpid()), element: el, pid: getpid())
    }

    private func windowRowTitle(_ m: SearchModel, _ id: CGWindowID) -> String? {
        m.results.first { $0.candidate.target == .window(id) }?.candidate.title
    }

    func testWindowRowNamesTheScannedActiveTabNotTheStoredTitle() {
        // Strip's stored title is stale (a tab switch never updates it); the scan saw the live tab.
        let m = SearchModel()
        m.setRail(rail([(1, "Old tab title")]))
        m.begin()
        m.setTabs([tab(1, "Live active tab", selected: true), tab(1, "Other", selected: false)], for: 1)
        m.setQuery("firefox")
        XCTAssertEqual(windowRowTitle(m, 1), "Live active tab")
    }

    func testMidSearchRetitleDoesNotChangeTheWindowRow() {
        // A peek switches the real tab; a reconcile then re-reads the title mid-search. Picking the
        // window restores its original tab, so the row must keep naming that.
        let m = SearchModel()
        m.setRail(rail([(1, "Original")]))
        m.begin()
        XCTAssertEqual(m.setRail(rail([(1, "Peeked tab")])), 1)
        m.setQuery("firefox")
        XCTAssertEqual(windowRowTitle(m, 1), "Original")
    }

    func testNewQuerySelectsTheNewBestHit() {
        // Review finding (2026-10-27): `h` puts the window "Home" first; typing on to `he` re-ranks
        // the tabs above it, but the old top hit stayed selected — ↩ picked it, peek pressed it, and
        // the list scrolled to it, pushing the new top rows out of view ("tabs disappear").
        let m = SearchModel()
        m.setRail(rail([(1, "Home")]))
        m.begin()
        m.setTabs([tab(1, "Home", selected: true, index: 0), tab(1, "Hello there", selected: false, index: 1),
                   tab(1, "Help center", selected: false, index: 2)], for: 1)
        m.setQuery("h")
        m.setQuery("he")
        XCTAssertEqual(m.selected, 0)
        XCTAssertEqual(m.selectedTarget, m.results.first?.candidate.target)
        XCTAssertNotEqual(m.selectedTarget, .window(1), "the previous top hit must not stay selected")
    }

    func testTabsStreamingInKeepTheSelectedTarget() {
        let m = SearchModel()
        m.setRail(rail([(1, "Alpha notes"), (2, "Alpha plan")]))
        m.begin()
        m.setQuery("alpha")
        m.moveSelection(1)
        let chosen = m.selectedTarget
        m.setTabs([tab(1, "Alpha", selected: false, index: 0)], for: 1) // a scan lands mid-browse
        XCTAssertEqual(m.selectedTarget, chosen)
    }

    func testEndForgetsSessionTitles() {
        let m = SearchModel()
        m.setRail(rail([(1, "Original")]))
        m.begin()
        m.end()
        m.setRail(rail([(1, "Now")]))
        m.begin()
        m.setQuery("firefox")
        XCTAssertEqual(windowRowTitle(m, 1), "Now")
    }
}

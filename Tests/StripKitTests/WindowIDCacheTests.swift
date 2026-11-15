import XCTest
import ApplicationServices
@testable import StripKit

/// The window-id cache behind `axWindowID`: equal elements share an entry, a destroyed window's
/// element is forgotten, and the cache can't grow without bound. (No Accessibility grant needed:
/// creating application elements doesn't talk to the app.)
final class WindowIDCacheTests: XCTestCase {
    func testEqualElementsShareAnEntryAndForgettingDropsIt() {
        let cache = WindowIDCache()
        let a = AXUIElementCreateApplication(4242)
        let sameApp = AXUIElementCreateApplication(4242)
        let other = AXUIElementCreateApplication(4243)
        cache.remember(77, for: a)
        XCTAssertEqual(cache.id(of: sameApp), 77, "a fresh element for the same thing hits")
        XCTAssertNil(cache.id(of: other))
        cache.forget(sameApp)
        XCTAssertNil(cache.id(of: a))
    }

    func testAnAppThatQuitsIsForgotten() {
        let cache = WindowIDCache()
        cache.remember(1, for: AXUIElementCreateApplication(5001))
        cache.remember(2, for: AXUIElementCreateApplication(5002))
        cache.forget(pid: 5001)
        XCTAssertNil(cache.id(of: AXUIElementCreateApplication(5001)))
        XCTAssertEqual(cache.id(of: AXUIElementCreateApplication(5002)), 2)
    }

    func testTheCacheIsBounded() {
        let cache = WindowIDCache()
        for pid in 0..<Int32(WindowIDCache.limit + 10) {
            cache.remember(CGWindowID(pid), for: AXUIElementCreateApplication(pid + 10_000))
        }
        XCTAssertLessThanOrEqual(cache.count, WindowIDCache.limit)
        XCTAssertEqual(cache.id(of: AXUIElementCreateApplication(Int32(WindowIDCache.limit + 9) + 10_000)),
                       CGWindowID(WindowIDCache.limit + 9), "the newest entry survives a reset")
    }
}

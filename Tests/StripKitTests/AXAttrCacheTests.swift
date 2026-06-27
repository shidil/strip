import XCTest
@testable import StripKit

/// Exercises `AXAttrCache`'s memo + prune-to-seen invalidation with synthetic keys (no AX). This is
/// the immutable-attribute cache behind perf 2.5a; the guarantees that matter are: a hit never
/// recomputes, `retain` drops only unseen keys, and a dropped-then-reseen key recomputes (so a
/// closed-and-reopened window can't be served a stale value).
final class AXAttrCacheTests: XCTestCase {
    func testMissComputesAndHitDoesNot() {
        let cache = AXAttrCache<Int, String>()
        var computeCount = 0
        let compute: (String) -> () -> String = { value in { computeCount += 1; return value } }

        XCTAssertEqual(cache.value(for: 1, compute: compute("a")), "a")
        XCTAssertEqual(computeCount, 1)

        // Hit: returns the memoized value, does not recompute (even with a different compute closure).
        XCTAssertEqual(cache.value(for: 1, compute: compute("b")), "a")
        XCTAssertEqual(computeCount, 1)
        XCTAssertEqual(cache.count, 1)
    }

    func testRetainDropsUnseenKeepsSeen() {
        let cache = AXAttrCache<Int, Int>()
        for k in 1...4 { _ = cache.value(for: k) { k * 10 } }
        XCTAssertEqual(cache.count, 4)

        cache.retain([2, 4])
        XCTAssertEqual(cache.count, 2)

        // Seen keys are untouched — still served without recompute.
        var recomputed = false
        XCTAssertEqual(cache.value(for: 2) { recomputed = true; return -1 }, 20)
        XCTAssertEqual(cache.value(for: 4) { recomputed = true; return -1 }, 40)
        XCTAssertFalse(recomputed)
    }

    func testRetainWithEmptySetClearsEverything() {
        let cache = AXAttrCache<Int, Int>()
        for k in 1...3 { _ = cache.value(for: k) { k } }
        cache.retain([])
        XCTAssertEqual(cache.count, 0)
    }

    func testRetainKeepsAllWhenEverythingSeen() {
        let cache = AXAttrCache<Int, Int>()
        for k in 1...3 { _ = cache.value(for: k) { k } }
        // Same-size, same-keys fast path must not drop anything.
        cache.retain([1, 2, 3])
        XCTAssertEqual(cache.count, 3)
        var recomputed = false
        XCTAssertEqual(cache.value(for: 2) { recomputed = true; return -1 }, 2)
        XCTAssertFalse(recomputed)
    }

    func testRetainSameSizeDifferentKeysPrunes() {
        // Guards the count-equality fast path: equal sizes but different membership must still prune.
        let cache = AXAttrCache<Int, Int>()
        for k in 1...3 { _ = cache.value(for: k) { k } }
        cache.retain([1, 2, 99]) // same count (3), but 3 is gone and 99 was never cached
        XCTAssertEqual(cache.count, 2)
        XCTAssertTrue([1, 2].allSatisfy { key in
            var recomputed = false
            _ = cache.value(for: key) { recomputed = true; return -1 }
            return !recomputed
        })
    }

    func testDroppedThenReseenRecomputes() {
        let cache = AXAttrCache<Int, String>()
        var computeCount = 0
        XCTAssertEqual(cache.value(for: 1) { computeCount += 1; return "first" }, "first")
        XCTAssertEqual(computeCount, 1)

        cache.retain([]) // key 1 evicted

        // Reseeing key 1 must recompute — never serve the evicted value. (A closed window's element
        // is gone; were the same key to recur it must re-read, not resurrect a stale attribute.)
        XCTAssertEqual(cache.value(for: 1) { computeCount += 1; return "second" }, "second")
        XCTAssertEqual(computeCount, 2)
    }

    func testStoresOptionalValues() {
        // The production caches store `String?` (role/subrole can legitimately be nil); a cached nil
        // must be a hit, not a perpetual miss.
        let cache = AXAttrCache<Int, String?>()
        var computeCount = 0
        XCTAssertNil(cache.value(for: 1) { computeCount += 1; return nil })
        XCTAssertNil(cache.value(for: 1) { computeCount += 1; return "x" })
        XCTAssertEqual(computeCount, 1)
    }
}

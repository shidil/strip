import XCTest
@testable import StripKit

final class OverviewGridTests: XCTestCase {
    // 7 cards, 3 per row — a ragged last row (rows: [0,1,2] [3,4,5] [6]).
    private let count = 7
    private let perRow = 3

    func testRightStepsAndWrapsAtEnd() {
        XCTAssertEqual(nextOverviewIndex(from: 0, count: count, perRow: perRow, .right), 1)
        XCTAssertEqual(nextOverviewIndex(from: 5, count: count, perRow: perRow, .right), 6)
        // Past the last card wraps to the first.
        XCTAssertEqual(nextOverviewIndex(from: 6, count: count, perRow: perRow, .right), 0)
    }

    func testLeftStepsAndWrapsAtStart() {
        XCTAssertEqual(nextOverviewIndex(from: 6, count: count, perRow: perRow, .left), 5)
        XCTAssertEqual(nextOverviewIndex(from: 1, count: count, perRow: perRow, .left), 0)
        // Before the first card wraps to the last.
        XCTAssertEqual(nextOverviewIndex(from: 0, count: count, perRow: perRow, .left), 6)
    }

    func testDownMovesByRowAndWraps() {
        XCTAssertEqual(nextOverviewIndex(from: 0, count: count, perRow: perRow, .down), 3)
        XCTAssertEqual(nextOverviewIndex(from: 3, count: count, perRow: perRow, .down), 6)
        // 6 + 3 = 9, wraps mod 7 → 2.
        XCTAssertEqual(nextOverviewIndex(from: 6, count: count, perRow: perRow, .down), 2)
    }

    func testUpMovesByRowAndWraps() {
        XCTAssertEqual(nextOverviewIndex(from: 6, count: count, perRow: perRow, .up), 3)
        XCTAssertEqual(nextOverviewIndex(from: 3, count: count, perRow: perRow, .up), 0)
        // 0 - 3 = -3, wraps mod 7 → 4.
        XCTAssertEqual(nextOverviewIndex(from: 0, count: count, perRow: perRow, .up), 4)
    }

    func testSingleWindowEveryMoveStaysZero() {
        for nav: OverviewNav in [.left, .right, .up, .down] {
            XCTAssertEqual(nextOverviewIndex(from: 0, count: 1, perRow: perRow, nav), 0)
        }
    }

    func testEmptyGridIsSafe() {
        XCTAssertEqual(nextOverviewIndex(from: 0, count: 0, perRow: perRow, .right), 0)
    }

    func testOutOfRangeStartIsNormalized() {
        // A stale index past the end is brought back in range before moving.
        XCTAssertEqual(nextOverviewIndex(from: 99, count: count, perRow: perRow, .right), posMod(99 + 1, count))
    }

    func testFullRowGridWraps() {
        // 6 cards, 2 rows of 3 — clean rectangle.
        XCTAssertEqual(nextOverviewIndex(from: 2, count: 6, perRow: 3, .right), 3)
        XCTAssertEqual(nextOverviewIndex(from: 5, count: 6, perRow: 3, .right), 0)
        XCTAssertEqual(nextOverviewIndex(from: 4, count: 6, perRow: 3, .down), 1)
        XCTAssertEqual(nextOverviewIndex(from: 1, count: 6, perRow: 3, .up), 4)
    }
}

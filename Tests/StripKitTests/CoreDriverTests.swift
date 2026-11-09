import XCTest
import CoreGraphics
@testable import StripKit

/// The executor's handle on the reducer: it reduces exactly as `Reducer.reduce` does, keeps the
/// state, and records a session that `Replay` reads back.
final class CoreDriverTests: XCTestCase {
    func testTheDriverReducesKeepsTheStateAndRecordsAReplayableSession() {
        let start = Replay.Start(vis: CGRect(x: 0, y: 25, width: 3440, height: 1415))
        var lines: [String] = []
        let driver = CoreDriver(start) { lines.append($0) }
        let frame = CGRect(x: 900, y: 200, width: 1200, height: 900)
        let events: [Replay.Timed] = [
            .init(.windowsEnumerated([WindowInfo(id: 1, frame: frame), WindowInfo(id: 2, frame: frame)], focused: 1), at: 10),
            .init(.chord(.draw(.i), repeated: false), at: 10.5),
            .init(.tick, at: 10.67),
        ]
        var expected = start.state
        for e in events {
            let r = driver.send(e.event, now: e.at)
            XCTAssertEqual(r, Reducer.reduce(expected, e.event, now: e.at))
            expected = r.state
        }
        XCTAssertEqual(driver.state, expected)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(Replay.sessions(in: lines.joined(separator: "\n")), [Replay.Recording(start: start, events: events)])
        XCTAssertNil(Replay.run(Replay.Recording(start: start, events: events)).failure)
    }

    func testWithoutASinkNothingIsRecorded() {
        let driver = CoreDriver(Replay.Start(vis: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertTrue(driver.send(.tick, now: 1).effects.isEmpty)
    }
}

import XCTest
@testable import PaneModel

@MainActor
final class DownloadsTests: XCTestCase {
    func testProgressThenCompletion() {
        let s = DownloadsStore()
        var r = s.update(engineID: 7, name: "a.zip", path: "/tmp/a.zip", percent: 10, received: 10, total: 100, state: .inProgress)
        XCTAssertFalse(r.justCompleted)
        XCTAssertTrue(s.hasActive)
        r = s.update(engineID: 7, name: "a.zip", path: "/tmp/a.zip", percent: 60, received: 60, total: 100, state: .inProgress)
        XCTAssertEqual(s.items.count, 1, "updates of the same download don't add rows")
        XCTAssertEqual(s.activeFraction ?? 0, 0.6, accuracy: 0.001)
        r = s.update(engineID: 7, name: "a.zip", path: "/tmp/a.zip", percent: 100, received: 100, total: 100, state: .complete)
        XCTAssertTrue(r.justCompleted)
        XCTAssertFalse(s.hasActive)
        r = s.update(engineID: 7, name: "a.zip", path: "/tmp/a.zip", percent: 100, received: 100, total: 100, state: .complete)
        XCTAssertEqual(s.items.count, 2, "a finished item is never reopened; the engine reusing an id starts a new row")
    }

    func testNewestFirstAndClear() {
        let s = DownloadsStore()
        s.update(engineID: 1, name: "one", path: "/tmp/1", percent: 100, received: 1, total: 1, state: .complete)
        s.update(engineID: 2, name: "two", path: "/tmp/2", percent: 5, received: 1, total: 20, state: .inProgress)
        XCTAssertEqual(s.items.map(\.name), ["two", "one"])
        s.clearFinished()
        XCTAssertEqual(s.items.map(\.name), ["two"], "running downloads survive Clear")
    }

    func testCancelAndPersistence() throws {
        let s = DownloadsStore()
        s.update(engineID: 1, name: "x", path: "/tmp/x", percent: 30, received: 3, total: 10, state: .inProgress)
        s.update(engineID: 1, name: "x", path: "/tmp/x", percent: 30, received: 3, total: 10, state: .canceled)
        s.update(engineID: 2, name: "y", path: "/tmp/y", percent: 100, received: 5, total: 5, state: .complete)
        s.update(engineID: 3, name: "z", path: "/tmp/z", percent: 1, received: 1, total: 100, state: .inProgress)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID()).json")
        try s.save(to: url)
        let t = DownloadsStore()
        XCTAssertTrue(t.load(from: url))
        XCTAssertEqual(Set(t.items.map(\.name)), ["x", "y"], "downloads still running when the app quit aren't restored as running")
    }

    func testUnknownSizeHasNoFraction() {
        let s = DownloadsStore()
        s.update(engineID: 1, name: "n", path: "", percent: -1, received: 123, total: -1, state: .inProgress)
        XCTAssertNil(s.activeFraction)
    }
}

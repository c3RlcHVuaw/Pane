import CryptoKit
import XCTest
@testable import PaneModel
@testable import PaneUpdate

@MainActor
final class UpdateTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("upd-\(UUID())")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func waitFor(_ updater: DefaultAppUpdater, _ pred: (UpdateState) -> Bool) async {
        for _ in 0..<100 { if pred(updater.state) { return }; try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    func testFeedWithNewerBuildBecomesAvailable() async throws {
        let dir = try tempDir()
        let feed = dir.appendingPathComponent("latest.json")
        try #"{"version":"0.5.0","build":7,"notes":"Shiny","url":"Pane-0.5.0-7.zip","sha256":"abc"}"#.write(to: feed, atomically: true, encoding: .utf8)
        let u = DefaultAppUpdater(feedURL: feed, currentBuild: 3, appURL: dir.appendingPathComponent("Pane.app"), bundleID: "x", terminate: {})
        u.checkNow(userInitiated: false)
        await waitFor(u) { if case .available = $0 { return true }; return false }
        guard case .available(let info) = u.state else { return XCTFail("state: \(u.state)") }
        XCTAssertEqual(info.build, 7)
        XCTAssertEqual(info.url, dir.appendingPathComponent("Pane-0.5.0-7.zip").standardizedFileURL.absoluteURL, "relative URLs resolve against the feed")
    }

    func testSameBuildStaysIdle() async throws {
        let dir = try tempDir()
        let feed = dir.appendingPathComponent("latest.json")
        try #"{"version":"0.4.0","build":3,"url":"a.zip","sha256":"x"}"#.write(to: feed, atomically: true, encoding: .utf8)
        let u = DefaultAppUpdater(feedURL: feed, currentBuild: 3, appURL: dir, bundleID: "x", terminate: {})
        u.checkNow(userInitiated: true)
        await waitFor(u) { $0 != .checking }
        XCTAssertEqual(u.state, .idle)
    }

    func testBrokenFeedFailsOnlyWhenUserAsked() async throws {
        let dir = try tempDir()
        let feed = dir.appendingPathComponent("latest.json")
        try "nope".write(to: feed, atomically: true, encoding: .utf8)
        let quiet = DefaultAppUpdater(feedURL: feed, currentBuild: 1, appURL: dir, bundleID: "x", terminate: {})
        quiet.checkNow(userInitiated: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(quiet.state, .idle)
        let loud = DefaultAppUpdater(feedURL: feed, currentBuild: 1, appURL: dir, bundleID: "x", terminate: {})
        loud.checkNow(userInitiated: true)
        await waitFor(loud) { $0 != .checking }
        guard case .failed = loud.state else { return XCTFail("state: \(loud.state)") }
    }

    func testChecksumMismatchIsRejected() async throws {
        let dir = try tempDir()
        let zip = dir.appendingPathComponent("a.zip")
        try Data("not really a zip".utf8).write(to: zip)
        let feed = dir.appendingPathComponent("latest.json")
        try #"{"version":"9","build":9,"url":"a.zip","sha256":"deadbeef"}"#.write(to: feed, atomically: true, encoding: .utf8)
        var terminated = false
        let u = DefaultAppUpdater(feedURL: feed, currentBuild: 1, appURL: dir.appendingPathComponent("Pane.app"), bundleID: "x", terminate: { terminated = true })
        u.checkNow(userInitiated: false)
        await waitFor(u) { if case .available = $0 { return true }; return false }
        u.install()
        await waitFor(u) { if case .failed = $0 { return true }; return false }
        guard case .failed(let msg) = u.state else { return XCTFail("state: \(u.state)") }
        XCTAssertTrue(msg.contains("checksum"), msg)
        XCTAssertFalse(terminated, "never quit for a bad download")
    }

    func testInstallScriptShape() {
        let s = UpdateInstaller.script(pid: 42, app: "/Applications/Pane.app", new: "/tmp/x/Pane.app", backup: "/Applications/.Pane.app.old")
        XCTAssertTrue(s.contains("kill -0"))
        XCTAssertTrue(s.contains("mv \"$BACKUP\" \"$APP\""), "rolls back if the swap fails")
        XCTAssertTrue(s.contains("open \"$APP\""))
        XCTAssertTrue(UpdateInstaller.script(pid: 1, app: "/a/it's/Pane.app", new: "n", backup: "b").contains("'/a/it'\\''s/Pane.app'"), "quotes paths safely")
    }
}

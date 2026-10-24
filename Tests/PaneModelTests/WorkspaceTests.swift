import XCTest
@testable import PaneModel

@MainActor
final class WorkspaceTests: XCTestCase {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testAddRenameRemoveAndPersistence() {
        let d = tempDir()
        let s = WorkspaceStore(directory: d)
        XCTAssertEqual(s.workspaces.count, 1)
        let w = s.add(name: "Design")!
        XCTAssertNil(s.add(name: "design"), "names are unique, ignoring case")
        s.activate(w.id)
        XCTAssertEqual(WorkspaceStore(directory: d).active.name, "Design")
        s.rename(w.id, to: "Work")
        XCTAssertEqual(WorkspaceStore(directory: d).active.name, "Work")
        s.remove(WorkspaceStore.mainID)
        XCTAssertEqual(s.workspaces.count, 2, "main can't be removed")
        s.remove(w.id)
        XCTAssertEqual(s.activeID, WorkspaceStore.mainID)
        XCTAssertEqual(WorkspaceStore(directory: d).workspaces.count, 1)
    }

    func testSwappingSessions() {
        let d = tempDir()
        let ws = WorkspaceStore(directory: d)
        let store = TabStore()
        store.addTab(url: "https://a.example")
        store.addTab(url: "https://b.example")
        try? store.save(to: ws.sessionURL(for: ws.activeID)!)
        let other = ws.add(name: "Other")!
        store.replaceSession(from: ws.sessionURL(for: other.id), freshTabURL: "https://new.example")
        XCTAssertEqual(store.tabs.map(\.url), ["https://new.example"])
        store.addTab(url: "https://c.example")
        try? store.save(to: ws.sessionURL(for: other.id)!)
        store.replaceSession(from: ws.sessionURL(for: WorkspaceStore.mainID), freshTabURL: "x")
        XCTAssertEqual(store.tabs.map(\.url), ["https://a.example", "https://b.example"])
    }

    func testWhatsNewNotes() {
        let defaults = UserDefaults(suiteName: "wn-\(UUID().uuidString)")!
        WhatsNew.save(version: "0.4.0", build: 30, notes: "One; Two\nThree", defaults: defaults)
        XCTAssertNil(WhatsNew.pending(currentBuild: 29, defaults: defaults))
        XCTAssertEqual(WhatsNew.pending(currentBuild: 30, defaults: defaults)?.lines, ["One", "Two", "Three"])
        WhatsNew.clear(defaults: defaults)
        XCTAssertNil(WhatsNew.pending(currentBuild: 30, defaults: defaults))
    }
}

final class WatchTests: XCTestCase {
    func testPlainTextAndConditions() {
        let html = "<html><style>p{}</style><script>var x='in stock'</script><p>Price:&nbsp;<b>49</b> &amp; free shipping</p></html>"
        let text = WatchChecker.plainText(fromHTML: html)
        XCTAssertEqual(text, "Price: 49 & free shipping")
        let a = PageWatch(url: "https://x.example", text: "FREE shipping", mode: .appears, title: "x")
        XCTAssertTrue(WatchChecker.isMet(a, pageText: text))
        let d = PageWatch(url: "https://x.example", text: "sold out", mode: .disappears, title: "x")
        XCTAssertTrue(WatchChecker.isMet(d, pageText: text))
        var c = PageWatch(url: "https://x.example", text: "", mode: .changes, title: "x", baseline: WatchChecker.fingerprint(text))
        XCTAssertFalse(WatchChecker.isMet(c, pageText: text))
        c.baseline = WatchChecker.fingerprint("other")
        XCTAssertTrue(WatchChecker.isMet(c, pageText: text))
    }
}


final class PriceWatchTests: XCTestCase {
    func testNumberParsingAndThresholds() {
        XCTAssertEqual(WatchChecker.number(after: "Цена", in: "Товар. Цена: 49 990 ₽ в наличии"), 49990)
        XCTAssertEqual(WatchChecker.number(after: "Price", in: "Price $1,299.50 today"), 1299.5)
        XCTAssertEqual(WatchChecker.number(after: "Price", in: "Price 1.299,50 €"), 1299.5)
        XCTAssertEqual(WatchChecker.number(after: "Price", in: "Price 49 only"), 49)
        XCTAssertNil(WatchChecker.number(after: "Cost", in: "Price 49"))
        let below = PageWatch(url: "https://x.example", text: "Цена", mode: .below, title: "x", threshold: 50000)
        XCTAssertTrue(WatchChecker.isMet(below, pageText: "Цена: 49 990 ₽"))
        XCTAssertFalse(WatchChecker.isMet(below, pageText: "Цена: 52 000 ₽"))
        let above = PageWatch(url: "https://x.example", text: "Price", mode: .above, title: "x", threshold: 100)
        XCTAssertTrue(WatchChecker.isMet(above, pageText: "Price 120"))
    }
}


final class CrashReportTests: XCTestCase {
    func testSummaryHasNoPathsOrPersonalData() {
        let header = "{\"app_name\":\"Pane\"}\n"
        let body = #"{"bundleInfo":{"CFBundleShortVersionString":"0.4.0","CFBundleVersion":"31"},"osVersion":{"train":"macOS 27.0"},"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"captureTime":"2026-10-23 21:33:47","faultingThread":0,"threads":[{"name":"CrBrowserMain","frames":[{"imageIndex":0,"symbol":"doThing"},{"imageIndex":1,"imageOffset":4096}]}],"usedImages":[{"name":"Chromium Embedded Framework","path":"/Users/secret/Pane.app/x"},{"name":"Pane"}]}"#
        let s = CrashReporter.summary(fromIPS: header + body)
        XCTAssertEqual(s?.app, "0.4.0 (31)")
        XCTAssertEqual(s?.kind, "EXC_BAD_ACCESS / SIGSEGV")
        XCTAssertEqual(s?.frames, ["Chromium Embedded Framework: doThing", "Pane: 0x1000"])
        XCTAssertFalse(s?.text.contains("secret") ?? true)
    }

    func testCleanExitFlag() {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("flag-\(UUID())")
        XCTAssertNil(CrashReporter.markLaunch(in: d))
        XCTAssertNotNil(CrashReporter.markLaunch(in: d), "a second launch without a clean exit means the first one crashed")
        CrashReporter.markCleanExit(in: d)
        XCTAssertNil(CrashReporter.markLaunch(in: d))
    }
}

@MainActor
final class NotesAndHistoryTests: XCTestCase {
    func testNotesPerPage() {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID())")
        let n = NoteStore(directory: d)
        n.set(url: "https://example.com/a?x=1", title: "A", text: "ask Anna")
        XCTAssertEqual(n.note(forURL: "https://example.com/a?x=1")?.text, "ask Anna")
        n.set(url: "https://example.com/a?x=1", title: "A", text: "ask Anna and Bob")
        XCTAssertEqual(n.notes.count, 1)
        XCTAssertEqual(NoteStore(directory: d).notes.first?.text, "ask Anna and Bob")
        n.set(url: "https://example.com/a?x=1", title: "A", text: "  ")
        XCTAssertTrue(n.notes.isEmpty, "empty text removes the note")
    }

    func testHistorySnippetIsKeptAndTrimmed() {
        let h = HistoryStore()
        h.record(url: "https://example.com/p", title: "Prices")
        h.updateSnippet(url: "https://example.com/p", snippet: String(repeating: "x", count: 900))
        XCTAssertEqual(h.entries.first?.snippet?.count, 400)
    }

    func testAgentHistoryKeepsNewestFirstAndCaps() {
        let s = AgentHistoryStore(directory: nil)
        for i in 0..<45 { s.upsert(AgentRunRecord(id: UUID(), date: Date(), title: "run \(i)", items: [])) }
        XCTAssertEqual(s.runs.count, 40)
        XCTAssertEqual(s.runs.first?.title, "run 44")
    }
}

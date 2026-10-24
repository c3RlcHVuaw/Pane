import XCTest
@testable import PaneModel

@MainActor
final class TabStoreTests: XCTestCase {
    func testCloseActivatesNeighbour() {
        let s = TabStore()
        let a = s.addTab(url: "a"), b = s.addTab(url: "b"), c = s.addTab(url: "c")
        s.activate(b)
        s.close(b)
        XCTAssertEqual(s.activeTabID, c)
        s.close(c)
        XCTAssertEqual(s.activeTabID, a)
    }

    func testPinMoveAndGroups() {
        let s = TabStore()
        let a = s.addTab(url: "a"), b = s.addTab(url: "b")
        let g = s.createGroup(name: "G", colorIndex: 1)
        s.move(a, toGroup: g)
        XCTAssertEqual(s.tabs(in: g).map(\.id), [a])
        XCTAssertEqual(s.ungrouped.map(\.id), [b])
        s.pin(a)
        XCTAssertEqual(s.pinned.map(\.id), [a])
        XCTAssertTrue(s.tabs(in: g).isEmpty)
        s.move(b, toGroup: g, before: nil)
        s.move(a, toGroup: g, before: b)
        XCTAssertEqual(s.tabs(in: g).map(\.id), [a, b])
        s.deleteGroup(g)
        XCTAssertEqual(s.ungrouped.count, 2)
    }

    func testSleepRules() {
        let s = TabStore()
        let a = s.addTab(url: "a"), b = s.addTab(url: "b", activate: false), p = s.addTab(url: "p", activate: false)
        s.pin(p)
        XCTAssertFalse(s.sleep(a), "active tab can't sleep")
        XCTAssertFalse(s.sleep(p), "pinned tab can't sleep")
        XCTAssertTrue(s.sleep(b))
        XCTAssertEqual(s.sleeping.map(\.id), [b])
        s.activate(b)
        XCTAssertTrue(s.sleeping.isEmpty, "activating wakes the tab")
    }

    func testSleepStale() {
        let s = TabStore()
        let a = s.addTab(url: "a"), b = s.addTab(url: "b", activate: false)
        XCTAssertTrue(s.sleepStale(olderThan: 60).isEmpty)
        let slept = s.sleepStale(olderThan: 60, now: Date().addingTimeInterval(3600))
        XCTAssertEqual(slept, [b])
        XCTAssertFalse(s.tab(a)!.isSleeping)
    }

    func testPersistenceRoundTrip() throws {
        let s = TabStore()
        let g = s.createGroup(name: "G", colorIndex: 2)
        s.addTab(url: "a", groupID: g)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pane-test-\(UUID()).json")
        try s.save(to: url)
        let t = TabStore()
        XCTAssertTrue(t.load(from: url))
        XCTAssertEqual(t.tabs, s.tabs)
        XCTAssertEqual(t.groups, s.groups)
        XCTAssertEqual(t.activeTabID, s.activeTabID)
    }

    func testTitleChangesDoNotRebuildTheList() {
        let s = TabStore()
        let a = s.addTab(url: "a")
        var structural = 0, updates: [UUID] = []
        s.onChange = { structural += 1 }
        s.onTabUpdate = { updates.append($0) }
        s.update(a, title: "Hello")
        s.update(a, title: "Hello")  // unchanged: no event
        s.update(a, url: "b")
        XCTAssertEqual(updates, [a, a])
        XCTAssertEqual(structural, 0, "title/url changes must not trigger a full sidebar reload")
        XCTAssertEqual(s.tab(a)?.title, "Hello")
    }

    func testAudibleTabsAreNotPutToSleep() {
        let s = TabStore()
        s.addTab(url: "a")
        let music = s.addTab(url: "m", activate: false)
        let idle = s.addTab(url: "i", activate: false)
        let slept = s.sleepStale(olderThan: 60, now: Date().addingTimeInterval(3600), excluding: [music])
        XCTAssertEqual(slept, [idle])
        XCTAssertFalse(s.tab(music)!.isSleeping)
    }

    func testCollapsingAGroupDoesNotRebuildTheList() {
        let s = TabStore()
        let g = s.createGroup(name: "G", colorIndex: 0)
        var structural = 0, silent = 0
        s.onChange = { structural += 1 }
        s.onSilentChange = { silent += 1 }
        s.setGroupCollapsed(g, true)
        s.setGroupCollapsed(g, true)  // no change, no event
        XCTAssertEqual(structural, 0, "a rebuild during the disclosure animation corrupted the outline")
        XCTAssertEqual(silent, 1)
        XCTAssertTrue(s.group(g)!.isCollapsed)
    }
}

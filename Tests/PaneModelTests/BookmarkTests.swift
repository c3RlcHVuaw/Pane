import XCTest
@testable import PaneModel
@testable import PaneImport

@MainActor
final class BookmarkStoreTests: XCTestCase {
    func testToggleAndLookup() {
        let s = BookmarkStore()
        XCTAssertTrue(s.toggle(title: "A", url: "https://a.com/"))
        XCTAssertTrue(s.isBookmarked("https://A.com"), "trailing slash and case are ignored")
        XCTAssertEqual(s.bar.children.count, 1)
        XCTAssertFalse(s.toggle(title: "A", url: "https://a.com"))
        XCTAssertTrue(s.bar.children.isEmpty)
    }

    func testMoveRules() {
        let s = BookmarkStore()
        let f = s.addFolder("F"), g = s.addFolder("G", in: f)
        let b = s.add(title: "B", url: "https://b.com", toFolder: g)
        XCTAssertFalse(s.move(f, toFolder: g), "folder can't move into its own descendant")
        XCTAssertFalse(s.move(s.bar.id, toFolder: f), "roots are fixed")
        XCTAssertTrue(s.move(b, toFolder: s.bar.id))
        XCTAssertEqual(s.bar.children.map(\.id), [b])
        let c = s.add(title: "C", url: "https://c.com")
        XCTAssertTrue(s.move(c, toFolder: s.bar.id, before: b))
        XCTAssertEqual(s.bar.children.map(\.id), [c, b])
        s.remove(f)
        XCTAssertNil(s.node(g))
    }

    func testImportTreeAndPersistence() throws {
        let s = BookmarkStore()
        XCTAssertEqual(s.importTree([.folder("X", [.link("A", "https://a.com")]), .link("B", "https://b.com")], folderName: "Imported"), 2)
        XCTAssertEqual(s.importTree([.folder("Empty")], folderName: "Nothing"), 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bm-\(UUID()).json")
        try s.save(to: url)
        let t = BookmarkStore()
        XCTAssertTrue(t.load(from: url))
        XCTAssertEqual(t.other, s.other)
    }
}

final class ImporterTests: XCTestCase {
    func testChrome() throws {
        let json = #"{"roots":{"bookmark_bar":{"children":[{"type":"url","name":"A","url":"https://a.com"},{"type":"folder","name":"F","children":[{"type":"url","name":"B","url":"https://b.com"}]}]},"other":{"children":[]}}}"#
        let r = try ChromeImporter().parse(Data(json.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].title, "Bookmarks Bar")
        XCTAssertEqual(r[0].bookmarkCount, 2)
        XCTAssertThrowsError(try ChromeImporter().parse(Data("{}".utf8)))
    }

    func testSafari() throws {
        let plist: [String: Any] = ["Children": [
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://a.com", "URIDictionary": ["title": "A"]]]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://r.com", "URIDictionary": ["title": "R"]]]],
            ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let r = try SafariImporter().parse(data)
        XCTAssertEqual(r.map(\.title), ["Favorites"])
        XCTAssertEqual(r[0].children.first?.url, "https://a.com")
    }

    func testArc() throws {
        let json = """
        {"sidebar":{"containers":[{"global":{}},{"spaces":[{"id":"s","title":"Work","containerIDs":["pinned","P","unpinned","U"]}],
        "items":["x",{"id":"P","data":{"itemContainer":{}},"childrenIds":["L","T1"]},
                 "y",{"id":"L","title":"Folder","data":{"list":{}},"childrenIds":["T2"]},
                 "z",{"id":"T1","title":"One","data":{"tab":{"savedURL":"https://one.com"}},"childrenIds":[]},
                 "w",{"id":"T2","data":{"tab":{"savedURL":"https://two.com","savedTitle":"Two"}},"childrenIds":[]}]}]}}
        """
        let r = try ArcImporter().parse(Data(json.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].title, "Work")
        XCTAssertEqual(r[0].bookmarkCount, 2)
        XCTAssertEqual(r[0].children[0].children[0].title, "Two")
    }

    func testHTML() throws {
        let html = """
        <DL><p><DT><H3>Bar</H3><DL><p><DT><A HREF="https://a.com" ADD_DATE="1">A &amp; B</A></DL><p>
        <DT><A HREF="https://c.com">C</A></DL>
        """
        let r = try HTMLImporter().parse(Data(html.utf8))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].title, "Bar")
        XCTAssertEqual(r[0].children[0].title, "A & B")
        XCTAssertEqual(r[1].url, "https://c.com")
    }
}

/// Opt-in: PANE_REAL_IMPORT=1 runs the importers against this machine's real browser data (counts only).
final class RealDataTests: XCTestCase {
    func testRealImporters() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PANE_REAL_IMPORT"] != nil)
        for imp in allImporters() {
            var total = 0, files = 0, failed = 0
            for f in imp.candidateFiles() {
                guard let d = try? Data(contentsOf: f) else { failed += 1; continue }
                files += 1
                total += (try? imp.parse(d))?.reduce(0) { $0 + $1.bookmarkCount } ?? 0
            }
            print("REAL \(imp.name): readable=\(files) unreadable=\(failed) bookmarks=\(total)")
        }
    }
}

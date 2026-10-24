import XCTest
@testable import PaneModel

final class StartPageTests: XCTestCase {
    private func entry(_ url: String, _ title: String, visits: Int, ago: TimeInterval) -> HistoryEntry {
        HistoryEntry(url: url, title: title, lastVisit: Date().addingTimeInterval(-ago), visits: visits)
    }

    func testBookmarksComeFirstThenFrequentSites() {
        let bar = [BookmarkNode.link("Mail", "https://mail.example.com"), .folder("Work", [.link("Hidden", "https://h.com")]), .link("News", "https://news.com")]
        let hist = [entry("https://often.com", "Often", visits: 9, ago: 100), entry("https://once.com", "Once", visits: 1, ago: 10)]
        let f = StartPageContent.favorites(bar: bar, history: hist)
        XCTAssertEqual(f.map(\.title), ["Mail", "News", "Often"], "folders are skipped; one-off visits aren't favorites")
    }

    func testOneTilePerSiteAndLimit() {
        let bar = (0..<12).map { BookmarkNode.link("S\($0)", "https://site\($0).com") }
        XCTAssertEqual(StartPageContent.favorites(bar: bar, history: []).count, 8)
        let dupes = [BookmarkNode.link("A", "https://www.same.com/a"), .link("B", "https://same.com/b")]
        XCTAssertEqual(StartPageContent.favorites(bar: dupes, history: []).count, 1, "www and non-www are the same site")
    }

    func testRecentsAreNewestFirstWithoutFavoritesOrRepeats() {
        let hist = [entry("https://a.com/1", "A1", visits: 1, ago: 300), entry("https://a.com/2", "A2", visits: 1, ago: 50),
                    entry("https://b.com", "B", visits: 1, ago: 200), entry("https://fav.com", "Fav", visits: 1, ago: 10)]
        let favs = [StartPageContent.Site(title: "Fav", url: "https://fav.com")]
        let r = StartPageContent.recents(history: hist, excluding: favs)
        XCTAssertEqual(r.map(\.title), ["A2", "B"])
    }

    func testGreeting() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int) -> Date { c.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h))! }
        XCTAssertEqual(StartPageContent.greeting(at: at(8), calendar: c), "Good morning")
        XCTAssertEqual(StartPageContent.greeting(at: at(14), calendar: c), "Good afternoon")
        XCTAssertEqual(StartPageContent.greeting(at: at(20), calendar: c), "Good evening")
        XCTAssertEqual(StartPageContent.greeting(at: at(2), calendar: c), "Good night")
    }
}

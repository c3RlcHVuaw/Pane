import XCTest
@testable import PaneModel
@testable import PaneSearch

final class SearchTests: XCTestCase {
    let p = DefaultSearchProvider()
    func item(_ id: String, _ kind: SearchItem.Kind, _ title: String, _ url: String, visits: Int = 0, used: Date? = nil) -> SearchItem {
        SearchItem(id: id, kind: kind, title: title, url: url, lastUsed: used, visits: visits)
    }

    func testPageSnippetsAreSearchable() {
        var a = item("1", .history, "Pricing", "https://example.com/p")
        a.detail = "How we set prices for design subscriptions and why they changed in autumn"
        let b = item("2", .history, "Contact", "https://example.com/c")
        XCTAssertEqual(p.keywordSearch("subscriptions autumn", in: [a, b], limit: 5).first?.item.id, "1")
        XCTAssertTrue(p.keywordSearch("subscriptions", in: [b], limit: 5).isEmpty)
    }

    func testRussianWordForms() {
        let items = [item("1", .history, "Курсы валют на сегодня", "https://example.com/a"),
                     item("2", .history, "Рецепты борща", "https://example.com/b")]
        XCTAssertEqual(p.keywordSearch("курсов", in: items, limit: 5).first?.item.id, "1")
        XCTAssertEqual(p.keywordSearch("рецепт", in: items, limit: 5).first?.item.id, "2")
        XCTAssertEqual(p.keywordSearch("борщ", in: items, limit: 5).first?.item.id, "2")
        XCTAssertTrue(p.keywordSearch("машина", in: items, limit: 5).isEmpty)
    }

    func testPrefixAndHostMatching() {
        let items = [item("1", .history, "Swift.org - Swift programming language", "https://www.swift.org/"),
                     item("2", .history, "Sweet recipes", "https://example.com/sweet"),
                     item("3", .tab, "Hacker News", "https://news.ycombinator.com")]
        XCTAssertEqual(p.keywordSearch("swi", in: items, limit: 5).first?.item.id, "1")
        XCTAssertEqual(p.keywordSearch("ycombinator", in: items, limit: 5).first?.item.id, "3", "host match")
        XCTAssertTrue(p.keywordSearch("zzzz", in: items, limit: 5).isEmpty)
    }

    func testAllTokensMustMatch() {
        let items = [item("1", .history, "Apple iPhone price", "https://apple.com/iphone")]
        XCTAssertEqual(p.keywordSearch("apple price", in: items, limit: 5).count, 1)
        XCTAssertTrue(p.keywordSearch("apple banana", in: items, limit: 5).isEmpty)
    }

    func testKindsRankAndDeduplicate() {
        let url = "https://github.com/"
        let items = [item("h", .history, "GitHub", url, visits: 5), item("b", .bookmark, "GitHub", url),
                     item("t", .tab, "GitHub", url), item("o", .history, "GitHub Docs", "https://docs.github.com/")]
        let r = p.keywordSearch("github", in: items, limit: 5)
        XCTAssertEqual(r.count, 2, "same URL collapses to one hit")
        XCTAssertEqual(r.first?.item.id, "t", "open tab beats bookmark and history")
    }

    func testCyrillicAndDiacritics() {
        let items = [item("1", .bookmark, "Нейронки: подборка", "https://example.com/a"),
                     item("2", .history, "Café Crème", "https://example.com/b")]
        XCTAssertEqual(p.keywordSearch("нейр", in: items, limit: 5).first?.item.id, "1")
        XCTAssertEqual(p.keywordSearch("cafe", in: items, limit: 5).first?.item.id, "2")
    }

    func testFuzzySubsequence() {
        let items = [item("1", .history, "Hacker News", "https://news.ycombinator.com")]
        XCTAssertEqual(p.keywordSearch("hkr", in: items, limit: 5).count, 1)
    }

    func testMeaningFindsRelatedPages() async throws {
        try XCTSkipUnless(p.supportsMeaning(for: "dessert"), "no English word embedding on this Mac")
        let items = [item("1", .history, "Chocolate cake recipe - BBC Good Food", "https://bbc.com/food"),
                     item("2", .history, "Swift.org - Swift programming language", "https://swift.org")]
        let r = await p.semanticSearch("dessert", in: items, limit: 5)
        XCTAssertEqual(r.first?.item.id, "1")
        XCTAssertTrue(r.first?.viaMeaning ?? false)
        let none = await p.semanticSearch("гвоздь", in: items, limit: 5)
        XCTAssertTrue(none.isEmpty, "unsupported language yields nothing instead of noise")
    }
}

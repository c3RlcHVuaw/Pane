import XCTest
@testable import PaneModel

final class ClosedTabsTests: XCTestCase {
    func testLastClosedComesBackFirst() {
        var c = ClosedTabs()
        c.push(.init(url: "https://a.com", title: "A", groupID: nil))
        c.push(.init(url: "https://b.com", title: "B", groupID: nil))
        XCTAssertEqual(c.pop()?.title, "B")
        XCTAssertEqual(c.pop()?.title, "A")
        XCTAssertNil(c.pop())
    }

    func testBlankPagesAndDuplicatesAreIgnored() {
        var c = ClosedTabs()
        c.push(.init(url: "", title: "New Tab", groupID: nil))
        c.push(.init(url: "about:blank", title: "", groupID: nil))
        XCTAssertTrue(c.isEmpty)
        c.push(.init(url: "https://a.com", title: "A1", groupID: nil))
        c.push(.init(url: "https://b.com", title: "B", groupID: nil))
        c.push(.init(url: "https://a.com", title: "A2", groupID: nil))
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.pop()?.title, "A2")
    }

    func testLimit() {
        var c = ClosedTabs(limit: 3)
        for i in 0..<5 { c.push(.init(url: "https://\(i).com", title: "\(i)", groupID: nil)) }
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c.pop()?.title, "4")
    }
}

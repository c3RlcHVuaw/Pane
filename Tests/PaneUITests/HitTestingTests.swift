import AppKit
import XCTest
@testable import PaneUI

@MainActor
final class HitTestingTests: XCTestCase {
    /// The start page is a SwiftUI hosting view. Inside a real window the stock one kept answering hit tests while
    /// hidden, which swallowed every click meant for the web page beneath it (links, right-click, text selection).
    /// This guards the override; the real-window check is PANE_DEBUG_HIT (see main.swift), which prints the hit chain.
    func testHiddenStartPageNeverAnswersHitTests() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let page = NSView(frame: parent.bounds)
        parent.addSubview(page)
        let start = StartPageHostingView(rootView: StartPageView(model: StartPageModel()))
        start.frame = parent.bounds
        parent.addSubview(start)
        start.isHidden = true
        XCTAssertNil(start.hitTest(NSPoint(x: 200, y: 150)))
        XCTAssertTrue(parent.hitTest(NSPoint(x: 200, y: 150)) === page, "the click reaches the page underneath")
    }
}

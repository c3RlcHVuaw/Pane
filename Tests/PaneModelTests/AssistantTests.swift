import XCTest
@testable import PaneModel

private struct FakeProvider: LLMProvider {
    var chunks: [String]
    var failure: AssistantError?
    var onCall: (@Sendable (String, [LLMMessage]) -> Void)?
    func stream(system: String, messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        onCall?(system, messages)
        return AsyncThrowingStream { c in
            for ch in chunks { c.yield(ch) }
            if let f = failure { c.finish(throwing: f) } else { c.finish() }
        }
    }
}

@MainActor
final class AssistantSessionTests: XCTestCase {
    private func wait(_ s: AssistantSession) async { for _ in 0..<200 where s.isStreaming { try? await Task.sleep(nanoseconds: 10_000_000) } }

    func testStreamsAnAnswer() async {
        let s = AssistantSession { FakeProvider(chunks: ["Hel", "lo ", "there"]) }
        s.send("Hi")
        await wait(s)
        XCTAssertEqual(s.messages.map(\.text), ["Hi", "Hello there"])
        XCTAssertEqual(s.messages.last?.role, .assistant)
        XCTAssertFalse(s.isStreaming)
    }

    func testSharedPagesGoToTheModelButNotIntoTheBubble() async {
        final class Box: @unchecked Sendable { var sent: [LLMMessage] = [] }
        let box = Box()
        let s = AssistantSession { FakeProvider(chunks: ["ok"], onCall: { _, m in box.sent = m }) }
        s.send("What is the price?", contexts: [PageContext(title: "Shop", url: "https://shop.com", text: "Widget costs $5")])
        await wait(s)
        XCTAssertEqual(s.messages[0].text, "What is the price?")
        XCTAssertEqual(s.messages[0].sources, ["Shop"])
        XCTAssertTrue(box.sent[0].content.contains("Widget costs $5"))
        XCTAssertTrue(box.sent[0].content.contains("title=\"Shop\""))
        XCTAssertTrue(box.sent[0].content.hasSuffix("Question: What is the price?"))
    }

    func testFollowUpsKeepEarlierContext() async {
        final class Box: @unchecked Sendable { var sent: [LLMMessage] = [] }
        let box = Box()
        let s = AssistantSession { FakeProvider(chunks: ["answer"], onCall: { _, m in box.sent = m }) }
        s.send("First", contexts: [PageContext(title: "P", url: "https://p.com", text: "secret fact")])
        await wait(s)
        s.send("And then?")
        await wait(s)
        XCTAssertEqual(box.sent.map(\.role), ["user", "assistant", "user"])
        XCTAssertTrue(box.sent[0].content.contains("secret fact"), "the page stays in the conversation for follow-ups")
    }

    func testErrorsAreShownNotThrown() async {
        let s = AssistantSession { FakeProvider(chunks: [], failure: AssistantError("Invalid API key.")) }
        s.send("Hi")
        await wait(s)
        XCTAssertEqual(s.messages.last?.text, "Invalid API key.")
        XCTAssertEqual(s.messages.last?.isError, true)
    }

    func testMissingKeyExplainsWhatToDo() {
        let s = AssistantSession { nil }
        XCTAssertFalse(s.isConfigured)
        s.send("Hi")
        XCTAssertEqual(s.messages.count, 1)
        XCTAssertTrue(s.messages[0].text.contains("Settings"))
    }

    func testClearAndStop() async {
        let s = AssistantSession { FakeProvider(chunks: ["x"]) }
        s.send("Hi")
        await wait(s)
        s.clear()
        XCTAssertTrue(s.messages.isEmpty)
    }

    func testPageTrimming() {
        let long = String(repeating: "word ", count: 20_000)
        let c = PageContext(title: "T", url: "https://t.com", text: "a\n\n\n\n\nb   c" + long).trimmed(maxCharacters: 100)
        XCTAssertTrue(c.text.hasPrefix("a\n\nb c"))
        XCTAssertTrue(c.text.hasSuffix("[…page continues]"))
        XCTAssertLessThan(c.text.count, 140)
    }

    func testTotalBudgetAcrossPages() {
        let big = PageContext(title: "Big", url: "https://b.com", text: String(repeating: "x", count: 200_000))
        let composed = AssistantSession.compose("Q", contexts: [big, big, big, big])
        XCTAssertLessThan(composed.count, 70_000, "many large tabs can't blow past the total budget")
    }
}

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let md = "# Title\nIntro line\nsecond line\n\n- one\n- two\n3. three\n> quoted\n---\n```swift\nlet x = 1\n```\nDone"
        XCTAssertEqual(Markdown.blocks(md), [
            .heading(level: 1, text: "Title"), .paragraph("Intro line\nsecond line"),
            .bullet("one"), .bullet("two"), .numbered(3, "three"), .quote("quoted"), .rule,
            .code("let x = 1"), .paragraph("Done"),
        ])
    }

    func testUnfinishedCodeFenceWhileStreaming() {
        XCTAssertEqual(Markdown.blocks("Look:\n```\nlet a ="), [.paragraph("Look:"), .code("let a =")])
    }

    func testNotEveryHashIsAHeading() {
        XCTAssertEqual(Markdown.blocks("#hashtag"), [.paragraph("#hashtag")])
        XCTAssertEqual(Markdown.blocks("1.5 million"), [.paragraph("1.5 million")])
    }
}

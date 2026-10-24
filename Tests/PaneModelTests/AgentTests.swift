import XCTest
@testable import PaneModel

private final class ScriptedProvider: AgentProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [[AgentEvent]]
    private(set) var received: [[AgentMessage]] = []
    init(_ turns: [[AgentEvent]]) { self.turns = turns }
    func stream(system: String, messages: [AgentMessage], tools: [ToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        let events: [AgentEvent] = lock.withLock { received.append(messages); return turns.isEmpty ? [] : turns.removeFirst() }
        return AsyncThrowingStream { c in for e in events { c.yield(e) }; c.finish() }
    }
}

@MainActor
private final class FakeToolbox: AgentToolbox {
    var tools = [ToolSpec(name: "get_page_state", description: "", inputSchema: "{}"), ToolSpec(name: "click", description: "", inputSchema: "{}")]
    var risks: [String: ToolRisk] = [:]
    var ran: [String] = []
    var began = 0, ended = 0
    var delay: UInt64 = 0
    func describe(_ name: String, input: String) -> ToolDescription { ToolDescription(title: "Run \(name)", symbol: "hand.tap", risk: risks[name] ?? .safe) }
    func run(_ name: String, input: String) async -> ToolResult {
        ran.append(name)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return ToolResult("ok \(name)")
    }
    func agentWillBegin() { began += 1 }
    func agentDidEnd() { ended += 1 }
}

@MainActor
final class AgentTests: XCTestCase {
    private func wait(_ s: AgentSession, _ cond: () -> Bool = { false }) async {
        for _ in 0..<300 { if (!s.isRunning) || cond() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testRunsToolsThenAnswers() async {
        let box = FakeToolbox()
        let p = ScriptedProvider([
            [.text("Looking."), .toolCall(id: "1", name: "get_page_state", input: "{}")],
            [.toolCall(id: "2", name: "click", input: "{\"ref\":3}")],
            [.text("Done.")],
        ])
        let s = AgentSession(toolbox: box) { p }
        s.send("Do it")
        await wait(s)
        XCTAssertEqual(box.ran, ["get_page_state", "click"])
        XCTAssertEqual(box.began, 1); XCTAssertEqual(box.ended, 1)
        XCTAssertFalse(s.isRunning)
        let kinds = s.items.map { item -> String in
            switch item { case .user: "user"; case .assistant: "assistant"; case .step: "step"; case .notice: "notice" }
        }
        XCTAssertEqual(kinds, ["user", "assistant", "step", "step", "assistant"])
        // The model saw the first result when it was asked for the second step.
        XCTAssertEqual(p.received[1].last?.blocks, [.toolResult(id: "1", content: "ok get_page_state", isError: false)])
    }

    func testRiskyStepWaitsForApprovalAndRunsOnAllow() async {
        let box = FakeToolbox(); box.risks["click"] = .confirm
        let p = ScriptedProvider([[.toolCall(id: "1", name: "click", input: "{}")], [.text("ok")]])
        let s = AgentSession(toolbox: box) { p }
        s.send("Buy it")
        await wait(s) { s.pendingApproval != nil }
        XCTAssertEqual(s.pendingApproval?.id, "1")
        XCTAssertTrue(box.ran.isEmpty, "nothing runs before the user says yes")
        s.answer(approve: true)
        await wait(s)
        XCTAssertEqual(box.ran, ["click"])
        XCTAssertNil(s.pendingApproval)
    }

    func testDeclineSkipsTheStepAndTellsTheModel() async {
        let box = FakeToolbox(); box.risks["click"] = .confirm
        let p = ScriptedProvider([[.toolCall(id: "1", name: "click", input: "{}")], [.text("Understood.")]])
        let s = AgentSession(toolbox: box) { p }
        s.send("Delete everything")
        await wait(s) { s.pendingApproval != nil }
        s.answer(approve: false)
        await wait(s)
        XCTAssertTrue(box.ran.isEmpty)
        guard case .toolResult(_, let content, let isError)? = p.received[1].last?.blocks.first else { return XCTFail("no result") }
        XCTAssertTrue(isError)
        XCTAssertTrue(content.contains("declined"))
        XCTAssertTrue(s.items.contains { if case .step(let st) = $0 { return st.state == .denied }; return false })
    }

    func testForbiddenNeverRunsEvenWithConfirmationsOff() async {
        let box = FakeToolbox(); box.risks["click"] = .forbidden("Pane never fills passwords.")
        let p = ScriptedProvider([[.toolCall(id: "1", name: "click", input: "{}")], [.text("ok")]])
        let s = AgentSession(toolbox: box) { p }
        s.confirmImportantActions = false
        s.send("Log in")
        await wait(s)
        XCTAssertTrue(box.ran.isEmpty)
        guard case .toolResult(_, let content, true)? = p.received[1].last?.blocks.first else { return XCTFail("no result") }
        XCTAssertEqual(content, "Pane never fills passwords.")
    }

    func testConfirmationsCanBeTurnedOff() async {
        let box = FakeToolbox(); box.risks["click"] = .confirm
        let p = ScriptedProvider([[.toolCall(id: "1", name: "click", input: "{}")], [.text("ok")]])
        let s = AgentSession(toolbox: box) { p }
        s.confirmImportantActions = false
        s.send("Go")
        await wait(s)
        XCTAssertEqual(box.ran, ["click"])
        XCTAssertNil(s.pendingApproval)
    }

    func testStopCancelsWaitingAndLeavesNoSpinner() async {
        let box = FakeToolbox(); box.risks["click"] = .confirm
        let p = ScriptedProvider([[.toolCall(id: "1", name: "click", input: "{}")], [.text("never")]])
        let s = AgentSession(toolbox: box) { p }
        s.send("Go")
        await wait(s) { s.pendingApproval != nil }
        s.stop()
        await wait(s)
        XCTAssertFalse(s.isRunning)
        XCTAssertTrue(box.ran.isEmpty)
        XCTAssertFalse(s.items.contains { if case .step(let st) = $0 { return st.state == .running || st.state == .waiting }; return false })
        XCTAssertEqual(box.ended, 1)
    }

    func testStepLimit() async {
        let box = FakeToolbox()
        let p = ScriptedProvider((0..<60).map { [AgentEvent.toolCall(id: "x\($0)", name: "click", input: "{\"ref\": \($0)}")] })
        let s = AgentSession(toolbox: box) { p }
        s.send("Loop forever")
        await wait(s)
        XCTAssertEqual(box.ran.count, AgentSession.maxSteps)
        XCTAssertTrue(s.items.contains { if case .notice(_, let t, _) = $0 { return t.contains("30 steps") }; return false })
    }

    func testRepeatingTheSameCallStopsTheLoop() async {
        let box = FakeToolbox()
        let turn: [AgentEvent] = [.toolCall(id: "x", name: "click", input: "{}")]
        let p = ScriptedProvider(Array(repeating: turn, count: 60))
        let s = AgentSession(toolbox: box) { p }
        s.send("Loop forever")
        await wait(s)
        XCTAssertLessThan(box.ran.count, 8, "identical calls in a row are cut off")
        XCTAssertTrue(s.items.contains { if case .notice = $0 { return true }; return false })
    }

    func testOldPageSnapshotsArePruned() {
        func call(_ id: String) -> AgentMessage { AgentMessage(role: .assistant, blocks: [.toolUse(id: id, name: "get_page_state", input: "{}")]) }
        func result(_ id: String) -> AgentMessage { AgentMessage(role: .user, blocks: [.toolResult(id: id, content: "BIG \(id)", isError: false)]) }
        let msgs = [call("a"), result("a"), call("b"), result("b"), call("c"), result("c")]
        let out = AgentSession.pruned(msgs)
        XCTAssertEqual(out[1].blocks, [.toolResult(id: "a", content: "[older page snapshot removed]", isError: false)])
        XCTAssertEqual(out[3].blocks, [.toolResult(id: "b", content: "BIG b", isError: false)])
        XCTAssertEqual(out[5].blocks, [.toolResult(id: "c", content: "BIG c", isError: false)])
    }

    func testNoKeyExplainsWhatToDo() {
        let s = AgentSession(toolbox: FakeToolbox()) { nil }
        s.send("Hi")
        XCTAssertFalse(s.isRunning)
        XCTAssertTrue(s.items.contains { if case .notice(_, let t, true) = $0 { return t.contains("Settings") }; return false })
    }

    func testProviderErrorsBecomeNotices() async {
        struct Failing: AgentProvider {
            func stream(system: String, messages: [AgentMessage], tools: [ToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
                AsyncThrowingStream { $0.finish(throwing: AssistantError("Invalid API key.")) }
            }
        }
        let s = AgentSession(toolbox: FakeToolbox()) { Failing() }
        s.send("Hi")
        await wait(s)
        XCTAssertTrue(s.items.contains { if case .notice(_, "Invalid API key.", true) = $0 { return true }; return false })
    }
}

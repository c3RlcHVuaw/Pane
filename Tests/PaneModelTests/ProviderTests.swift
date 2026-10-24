import XCTest
@testable import PaneModel
@testable import PaneAssistant

/// Serves canned responses so the providers can be tested without a network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if let s = request.httpBodyStream { s.open(); var d = Data(); let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while s.hasBytesAvailable { let n = s.read(buf, maxLength: 4096); if n <= 0 { break }; d.append(buf, count: n) }
            buf.deallocate(); Self.lastBody = d } else { Self.lastBody = request.httpBody }
        let (status, data) = Self.handler?(request) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ProviderTests: XCTestCase {
    private var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }
    private func collect(_ s: AsyncThrowingStream<String, Error>) async throws -> String {
        var out = ""; for try await c in s { out += c }; return out
    }

    func testAnthropicStreamsTextAndSendsTheRightRequest() async throws {
        StubProtocol.handler = { _ in (200, Data("""
            event: message_start
            data: {"type":"message_start"}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}

            event: message_stop
            data: {"type":"message_stop"}

            """.utf8)) }
        let p = AnthropicProvider(apiKey: "sk-test", model: "claude-sonnet-5-5", session: session)
        let text = try await collect(p.stream(system: "sys", messages: [LLMMessage(role: "user", content: "hi")]))
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/v1/messages")
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body?["stream"] as? Bool, true)
        XCTAssertEqual(body?["system"] as? String, "sys")
    }

    func testAnthropicErrorEventsAndStatusCodes() async {
        StubProtocol.handler = { _ in (200, Data("data: {\"type\":\"error\",\"error\":{\"message\":\"Overloaded\"}}\n\n".utf8)) }
        let p = AnthropicProvider(apiKey: "k", model: "m", session: session)
        do { _ = try await collect(p.stream(system: "", messages: [])); XCTFail("should throw") }
        catch { XCTAssertEqual((error as? AssistantError)?.message, "Overloaded") }

        StubProtocol.handler = { _ in (401, Data("{\"error\":{\"message\":\"invalid x-api-key\"}}".utf8)) }
        do { _ = try await collect(p.stream(system: "", messages: [])); XCTFail("should throw") }
        catch { XCTAssertTrue((error as? AssistantError)?.message.contains("API key was rejected") ?? false) }

        StubProtocol.handler = { _ in (404, Data("{\"error\":{\"message\":\"model: nope\"}}".utf8)) }
        do { _ = try await collect(p.stream(system: "", messages: [])); XCTFail("should throw") }
        catch { XCTAssertTrue((error as? AssistantError)?.message.contains("model name") ?? false) }
    }

    func testOpenAIStyleStream() async throws {
        StubProtocol.handler = { _ in (200, Data("""
            data: {"choices":[{"delta":{"role":"assistant","content":""}}]}

            data: {"choices":[{"delta":{"content":"Hi"}}]}

            data: {"choices":[{"delta":{"content":" there"}}]}

            data: [DONE]

            """.utf8)) }
        let p = OpenAICompatibleProvider(apiKey: "sk-o", model: "gpt-4o-mini", baseURL: URL(string: "https://example.com/v1")!, session: session)
        let text = try await collect(p.stream(system: "sys", messages: [LLMMessage(role: "user", content: "yo")]))
        XCTAssertEqual(text, "Hi there")
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-o")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.absoluteString, "https://example.com/v1/chat/completions")
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody ?? Data()) as? [String: Any]
        XCTAssertEqual((body?["messages"] as? [[String: String]])?.first?["role"], "system")
    }

    func testFactoryNeedsAKeyExceptForLocalServers() {
        XCTAssertNil(AssistantProviders.make(provider: "anthropic", model: "m", baseURL: "", apiKey: nil))
        XCTAssertNil(AssistantProviders.make(provider: "anthropic", model: "m", baseURL: "", apiKey: "  "))
        XCTAssertNotNil(AssistantProviders.make(provider: "anthropic", model: "m", baseURL: "", apiKey: "k"))
        XCTAssertNil(AssistantProviders.make(provider: "openai", model: "m", baseURL: "", apiKey: nil))
        XCTAssertNotNil(AssistantProviders.make(provider: "openai", model: "llama3", baseURL: "http://localhost:11434/v1", apiKey: nil), "Ollama needs no key")
        XCTAssertNil(AssistantProviders.make(provider: "anthropic", model: "  ", baseURL: "", apiKey: "k"))
    }
}

/// Opt-in: PANE_OPENAI_KEY=… swift test --filter LiveAssistantTests — one tiny real request, plus a bad-key check.
final class LiveAssistantTests: XCTestCase {
    func testRealOpenAIStreamAndRejectedKey() async throws {
        guard let key = ProcessInfo.processInfo.environment["PANE_OPENAI_KEY"], !key.isEmpty else { throw XCTSkip("set PANE_OPENAI_KEY to run") }
        var text = ""
        let good = OpenAICompatibleProvider(apiKey: key, model: "gpt-4o-mini")
        for try await c in good.stream(system: "Answer with one word only.", messages: [LLMMessage(role: "user", content: "Reply with the word: pong")]) { text += c }
        XCTAssertTrue(text.lowercased().contains("pong"), "got: \(text)")

        let bad = OpenAICompatibleProvider(apiKey: "sk-invalid-key-for-test", model: "gpt-4o-mini")
        do {
            for try await _ in bad.stream(system: "", messages: [LLMMessage(role: "user", content: "hi")]) {}
            XCTFail("a bad key must fail")
        } catch {
            XCTAssertTrue((error as? AssistantError)?.message.contains("API key was rejected") ?? false, "\(error)")
        }
    }
}

final class AgentProviderTests: XCTestCase {
    private var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }
    private func events(_ s: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
        var out: [AgentEvent] = []; for try await e in s { out.append(e) }; return out
    }
    private let tools = [ToolSpec(name: "click", description: "Click", inputSchema: #"{"type":"object","properties":{"ref":{"type":"integer"}}}"#)]
    private let history = [
        AgentMessage(role: .user, blocks: [.text("Click 3")]),
        AgentMessage(role: .assistant, blocks: [.text("ok"), .toolUse(id: "t1", name: "click", input: #"{"ref":3}"#)]),
        AgentMessage(role: .user, blocks: [.toolResult(id: "t1", content: "Clicked", isError: false)]),
    ]

    func testAnthropicToolUseStream() async throws {
        StubProtocol.handler = { _ in (200, Data("""
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Clicking."}}

            data: {"type":"content_block_stop","index":0}

            data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"click","input":{}}}

            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"ref\\""}}

            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":": 7}"}}

            data: {"type":"content_block_stop","index":1}

            data: {"type":"message_stop"}

            """.utf8)) }
        let p = AnthropicProvider(apiKey: "k", model: "m", session: session)
        let ev = try await events(p.stream(system: "sys", messages: history, tools: tools))
        XCTAssertEqual(ev, [.text("Clicking."), .toolCall(id: "toolu_1", name: "click", input: #"{"ref": 7}"#)])
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody ?? Data()) as? [String: Any]
        XCTAssertEqual((body?["tools"] as? [[String: Any]])?.first?["name"] as? String, "click")
        let msgs = body?["messages"] as? [[String: Any]]
        let result = (msgs?.last?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(result?["type"] as? String, "tool_result")
        XCTAssertEqual(result?["tool_use_id"] as? String, "t1")
        let use = (msgs?[1]["content"] as? [[String: Any]])?.last
        XCTAssertEqual(use?["type"] as? String, "tool_use")
        XCTAssertEqual((use?["input"] as? [String: Any])?["ref"] as? Int, 3, "tool input goes back as an object, not a string")
    }

    func testToolWithNoArgumentsGetsEmptyObject() async throws {
        StubProtocol.handler = { _ in (200, Data("""
            data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"list_tabs","input":{}}}

            data: {"type":"content_block_stop","index":0}

            data: {"type":"message_stop"}

            """.utf8)) }
        let p = AnthropicProvider(apiKey: "k", model: "m", session: session)
        let ev = try await events(p.stream(system: "", messages: history, tools: tools))
        XCTAssertEqual(ev, [.toolCall(id: "t", name: "list_tabs", input: "{}")])
    }

    func testOpenAIToolCallStream() async throws {
        StubProtocol.handler = { _ in (200, Data("""
            data: {"choices":[{"delta":{"role":"assistant","content":"On it."}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"click","arguments":""}}]}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"ref\\":"}}]}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"9}"}}]}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"list_tabs","arguments":"{}"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """.utf8)) }
        let p = OpenAICompatibleProvider(apiKey: "k", model: "m", baseURL: URL(string: "https://example.com/v1")!, session: session)
        let ev = try await events(p.stream(system: "sys", messages: history, tools: tools))
        XCTAssertEqual(ev, [.text("On it."), .toolCall(id: "call_a", name: "click", input: #"{"ref":9}"#), .toolCall(id: "call_b", name: "list_tabs", input: "{}")])
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody ?? Data()) as? [String: Any]
        let msgs = body?["messages"] as? [[String: Any]]
        XCTAssertEqual(msgs?.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(msgs?[3]["tool_call_id"] as? String, "t1")
        let calls = msgs?[2]["tool_calls"] as? [[String: Any]]
        XCTAssertEqual((calls?.first?["function"] as? [String: Any])?["arguments"] as? String, #"{"ref":3}"#)
        XCTAssertEqual(((body?["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["name"] as? String, "click")
    }

    func testToolsNotSupportedGivesAHint() async {
        StubProtocol.handler = { _ in (400, Data(#"{"error":{"message":"tools is not supported"}}"#.utf8)) }
        let p = OpenAICompatibleProvider(apiKey: "k", model: "m", baseURL: URL(string: "https://example.com/v1")!, session: session)
        do { _ = try await events(p.stream(system: "", messages: history, tools: tools)); XCTFail("should throw") }
        catch { XCTAssertTrue((error as? AssistantError)?.message.contains("tools") ?? false) }
    }
}

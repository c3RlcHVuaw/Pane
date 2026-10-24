import Foundation
import PaneModel

private func jsonObject(_ text: String) -> Any {
    (try? JSONSerialization.jsonObject(with: Data((text.isEmpty ? "{}" : text).utf8))) ?? [String: Any]()
}

private func schemaObject(_ tool: ToolSpec) -> Any { jsonObject(tool.inputSchema) }

private func httpFailure(status: Int, body: Data) -> AssistantError {
    let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
        .flatMap { ($0["error"] as? [String: Any])?["message"] as? String ?? $0["error"] as? String }
    switch status {
    case 401, 403: return AssistantError(tr("The API key was rejected. Check it in Settings → Assistant."))
    case 404: return AssistantError(tr("The model or address wasn't found. Check the model name in Settings → Assistant.") + (detail.map { " (\($0))" } ?? ""))
    case 429: return AssistantError(tr("The provider is rate-limiting you. Wait a moment and try again.") + (detail.map { " (\($0))" } ?? ""))
    case 400: return AssistantError(detail ?? tr("The provider didn't accept the request (400). This model may not support tools."))
    case 500...599: return AssistantError(String(localized: "The provider had a problem (\(status)). Try again shortly."))
    default: return AssistantError(detail ?? String(localized: "The provider returned an error (\(status))."))
    }
}

private func readBody(_ bytes: URLSession.AsyncBytes) async -> Data {
    var data = Data()
    do { for try await b in bytes { data.append(b); if data.count > 20_000 { break } } } catch {}
    return data
}

private func wrapNetworkErrors(_ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation, _ body: @escaping @Sendable () async throws -> Void) -> Task<Void, Never> {
    Task {
        do { try await body(); continuation.finish() }
        catch is CancellationError { continuation.finish() }
        catch let e as URLError where e.code == .cancelled { continuation.finish() }
        catch let e as URLError { continuation.finish(throwing: AssistantError(String(localized: "Can't reach the provider. Check your connection. (\(e.localizedDescription))"))) }
        catch { continuation.finish(throwing: error) }
    }
}

// MARK: Anthropic

extension AnthropicProvider: AgentProvider {
    func encode(_ messages: [AgentMessage]) -> [[String: Any]] {
        messages.map { m in
            let content: [[String: Any]] = m.blocks.map { b in
                switch b {
                case .text(let t): return ["type": "text", "text": t]
                case .toolUse(let id, let name, let input): return ["type": "tool_use", "id": id, "name": name, "input": jsonObject(input)]
                case .toolResult(let id, let c, let err): return ["type": "tool_result", "tool_use_id": id, "content": c, "is_error": err]
                }
            }
            return ["role": m.role.rawValue, "content": content]
        }
    }

    public func stream(system: String, messages: [AgentMessage], tools: [ToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = wrapNetworkErrors(continuation) {
                var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"), timeoutInterval: 180)
                req.httpMethod = "POST"
                req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                var body: [String: Any] = ["model": model, "max_tokens": 4096, "stream": true, "system": system, "messages": encode(messages)]
                if !tools.isEmpty { body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": schemaObject($0)] } }
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (bytes, resp) = try await session.bytes(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw httpFailure(status: http.statusCode, body: await readBody(bytes))
                }
                var open: [Int: (id: String, name: String, json: String)] = [:]
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                    let index = obj["index"] as? Int ?? 0
                    switch obj["type"] as? String {
                    case "content_block_start":
                        if let b = obj["content_block"] as? [String: Any], b["type"] as? String == "tool_use" {
                            open[index] = (b["id"] as? String ?? UUID().uuidString, b["name"] as? String ?? "", "")
                        }
                    case "content_block_delta":
                        let d = obj["delta"] as? [String: Any]
                        if let t = d?["text"] as? String { continuation.yield(.text(t)) }
                        if let j = d?["partial_json"] as? String, var call = open[index] { call.json += j; open[index] = call }
                    case "content_block_stop":
                        if let call = open.removeValue(forKey: index) {
                            continuation.yield(.toolCall(id: call.id, name: call.name, input: call.json.isEmpty ? "{}" : call.json))
                        }
                    case "error":
                        throw AssistantError((obj["error"] as? [String: Any])?["message"] as? String ?? "The provider reported an error.")
                    case "message_stop": return
                    default: break
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: OpenAI and compatible

extension OpenAICompatibleProvider: AgentProvider {
    func encode(system: String, _ messages: [AgentMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m.role {
            case .user:
                let text = m.blocks.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n")
                for case .toolResult(let id, let c, let err) in m.blocks { out.append(["role": "tool", "tool_call_id": id, "content": err ? "Error: " + c : c]) }
                if !text.isEmpty { out.append(["role": "user", "content": text]) }
            case .assistant:
                let text = m.blocks.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n")
                let calls: [[String: Any]] = m.blocks.compactMap {
                    if case .toolUse(let id, let name, let input) = $0 {
                        return ["id": id, "type": "function", "function": ["name": name, "arguments": input.isEmpty ? "{}" : input]]
                    }
                    return nil
                }
                var msg: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
                if !calls.isEmpty { msg["tool_calls"] = calls }
                out.append(msg)
            }
        }
        return out
    }

    public func stream(system: String, messages: [AgentMessage], tools: [ToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = wrapNetworkErrors(continuation) {
                var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"), timeoutInterval: 180)
                req.httpMethod = "POST"
                if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                var body: [String: Any] = ["model": model, "stream": true, "messages": encode(system: system, messages)]
                if !tools.isEmpty {
                    body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": schemaObject($0)]] }
                }
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (bytes, resp) = try await session.bytes(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw httpFailure(status: http.statusCode, body: await readBody(bytes))
                }
                var calls: [Int: (id: String, name: String, args: String)] = [:]
                func flush() {
                    for k in calls.keys.sorted() {
                        let c = calls[k]!
                        continuation.yield(.toolCall(id: c.id.isEmpty ? "call_\(k)_\(UUID().uuidString.prefix(6))" : c.id, name: c.name, input: c.args.isEmpty ? "{}" : c.args))
                    }
                    calls.removeAll()
                }
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { flush(); return }
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                    if let err = obj["error"] as? [String: Any] { throw AssistantError(err["message"] as? String ?? "The provider reported an error.") }
                    guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
                    let delta = choice["delta"] as? [String: Any]
                    if let t = delta?["content"] as? String, !t.isEmpty { continuation.yield(.text(t)) }
                    for tc in delta?["tool_calls"] as? [[String: Any]] ?? [] {
                        let i = tc["index"] as? Int ?? 0
                        var c = calls[i] ?? ("", "", "")
                        if let id = tc["id"] as? String { c.id = id }
                        if let f = tc["function"] as? [String: Any] {
                            if let n = f["name"] as? String { c.name += n }
                            if let a = f["arguments"] as? String { c.args += a }
                        }
                        calls[i] = c
                    }
                    if choice["finish_reason"] as? String != nil, !(choice["finish_reason"] is NSNull) { flush() }
                }
                flush()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public extension AssistantProviders {
    /// Like `make`, but for the agent: the same providers, asked to call tools.
    static func makeAgent(provider: String, model: String, baseURL: String, apiKey: String?) -> AgentProvider? {
        make(provider: provider, model: model, baseURL: baseURL, apiKey: apiKey) as? AgentProvider
    }
}

import Foundation
import PaneModel

/// Reads a server-sent-events body line by line and hands each `data:` payload to `handle`.
private func forEachEvent(_ bytes: URLSession.AsyncBytes, _ handle: (String) throws -> Bool) async throws {
    for try await line in bytes.lines {
        guard line.hasPrefix("data:") else { continue }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if try handle(payload) { return }
    }
}

/// Turns an HTTP failure into something a person can act on.
private func failure(status: Int, body: Data) -> AssistantError {
    let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
        .flatMap { ($0["error"] as? [String: Any])?["message"] as? String ?? $0["error"] as? String }
    switch status {
    case 401, 403: return AssistantError(tr("The API key was rejected. Check it in Settings → Assistant."))
    case 404: return AssistantError(tr("The model or address wasn't found. Check the model name and address in Settings → Assistant.") + (detail.map { " (\($0))" } ?? ""))
    case 429: return AssistantError(tr("The provider is rate-limiting you. Wait a moment and try again.") + (detail.map { " (\($0))" } ?? ""))
    case 500...599: return AssistantError(String(localized: "The provider had a problem (\(status)). Try again shortly."))
    default: return AssistantError(detail ?? String(localized: "The provider returned an error (\(status))."))
    }
}

private func readBody(_ bytes: URLSession.AsyncBytes) async -> Data {
    var data = Data()
    do { for try await b in bytes { data.append(b); if data.count > 20_000 { break } } } catch {}
    return data
}

// MARK: Anthropic

public struct AnthropicProvider: LLMProvider {
    let apiKey: String, model: String, baseURL: URL, session: URLSession

    public init(apiKey: String, model: String, baseURL: URL = URL(string: "https://api.anthropic.com")!, session: URLSession = .shared) {
        self.apiKey = apiKey; self.model = model; self.baseURL = baseURL; self.session = session
    }

    public func stream(system: String, messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"), timeoutInterval: 120)
                    req.httpMethod = "POST"
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model, "max_tokens": 4096, "stream": true, "system": system,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    ] as [String: Any])
                    let (bytes, resp) = try await session.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw failure(status: http.statusCode, body: await readBody(bytes))
                    }
                    try await forEachEvent(bytes) { payload in
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return false }
                        switch obj["type"] as? String {
                        case "content_block_delta":
                            if let t = (obj["delta"] as? [String: Any])?["text"] as? String { continuation.yield(t) }
                        case "error":
                            throw AssistantError((obj["error"] as? [String: Any])?["message"] as? String ?? "The provider reported an error.")
                        case "message_stop": return true
                        default: break
                        }
                        return false
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch let e as URLError where e.code == .cancelled { continuation.finish() }
                catch let e as URLError { continuation.finish(throwing: AssistantError(String(localized: "Can't reach the provider. Check your connection. (\(e.localizedDescription))"))) }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: OpenAI and compatible servers (OpenRouter, Ollama, LM Studio, …)

public struct OpenAICompatibleProvider: LLMProvider {
    let apiKey: String, model: String, baseURL: URL, session: URLSession

    public init(apiKey: String, model: String, baseURL: URL = URL(string: "https://api.openai.com/v1")!, session: URLSession = .shared) {
        self.apiKey = apiKey; self.model = model; self.baseURL = baseURL; self.session = session
    }

    public func stream(system: String, messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"), timeoutInterval: 120)
                    req.httpMethod = "POST"
                    if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    let all = [["role": "system", "content": system]] + messages.map { ["role": $0.role, "content": $0.content] }
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true, "messages": all] as [String: Any])
                    let (bytes, resp) = try await session.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw failure(status: http.statusCode, body: await readBody(bytes))
                    }
                    try await forEachEvent(bytes) { payload in
                        if payload == "[DONE]" { return true }
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return false }
                        if let err = obj["error"] as? [String: Any] { throw AssistantError(err["message"] as? String ?? "The provider reported an error.") }
                        if let choice = (obj["choices"] as? [[String: Any]])?.first,
                           let t = (choice["delta"] as? [String: Any])?["content"] as? String { continuation.yield(t) }
                        return false
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch let e as URLError where e.code == .cancelled { continuation.finish() }
                catch let e as URLError { continuation.finish(throwing: AssistantError(String(localized: "Can't reach the provider. Check your connection. (\(e.localizedDescription))"))) }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: Factory

public enum AssistantProviders {
    public static let anthropicModels = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    public static let openAIModels = ["gpt-4o-mini", "gpt-4o"]

    /// Builds the provider for the current settings, or nil when there's no key (or no address).
    public static func make(provider: String, model: String, baseURL: String, apiKey: String?) -> LLMProvider? {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let m = model.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return nil }
        let custom = baseURL.trimmingCharacters(in: .whitespaces)
        if provider == "openai" {
            let url = custom.isEmpty ? URL(string: "https://api.openai.com/v1") : URL(string: custom)
            // Local servers (Ollama, LM Studio) don't need a key; the real OpenAI does.
            let isLocal = url?.host == "localhost" || url?.host == "127.0.0.1"
            guard let url, !key.isEmpty || isLocal else { return nil }
            return OpenAICompatibleProvider(apiKey: key, model: m, baseURL: url)
        }
        guard !key.isEmpty else { return nil }
        return AnthropicProvider(apiKey: key, model: m, baseURL: URL(string: custom.isEmpty ? "https://api.anthropic.com" : custom)!)
    }
}

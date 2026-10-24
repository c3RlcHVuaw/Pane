import Combine
import Foundation

public struct AssistantError: Error, LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A page (or tab) the user chose to share with the assistant.
public struct PageContext: Equatable, Sendable, Identifiable {
    public var id: String { url }
    public var title: String
    public var url: String
    public var text: String

    public init(title: String, url: String, text: String) { self.title = title; self.url = url; self.text = text }

    /// Collapses blank runs and cuts the text so one huge page can't use the whole budget.
    public func trimmed(maxCharacters: Int) -> PageContext {
        var t = text.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > maxCharacters { t = String(t.prefix(maxCharacters)) + "\n[…page continues]" }
        return PageContext(title: title, url: url, text: t)
    }
}

public struct LLMMessage: Equatable, Sendable {
    public var role: String  // "user" | "assistant"
    public var content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

/// Anything that can stream a model's answer. Implemented in PaneAssistant.
public protocol LLMProvider: Sendable {
    func stream(system: String, messages: [LLMMessage]) -> AsyncThrowingStream<String, Error>
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    public var text: String
    public var isError: Bool
    /// Titles of the pages that were shared with this message.
    public var sources: [String]
    /// What the model actually received for a user message (page text included).
    fileprivate var modelText: String

    fileprivate init(role: Role, text: String, isError: Bool = false, sources: [String] = [], modelText: String? = nil) {
        id = UUID(); self.role = role; self.text = text; self.isError = isError; self.sources = sources; self.modelText = modelText ?? text
    }
}

/// One conversation with the assistant. It lives only as long as the panel session; nothing is stored.
@MainActor
public final class AssistantSession: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isStreaming = false

    private let providerFactory: () -> LLMProvider?
    private var task: Task<Void, Never>?

    public static let perPageLimit = 24_000
    public static let totalLimit = 60_000

    public init(providerFactory: @escaping () -> LLMProvider?) { self.providerFactory = providerFactory }

    public var isConfigured: Bool { providerFactory() != nil }
    /// A provider for the current settings, for a connection test.
    public func makeProvider() -> LLMProvider? { providerFactory() }

    public static func systemPrompt(now: Date = Date()) -> String {
        """
        You are the assistant built into Pane, a web browser. Today is \(now.formatted(.iso8601.year().month().day())).
        Reply in the language the user writes in. Be concise and direct.
        When the user shares pages, base your answer on them and name the page (by its title) that a fact comes from. \
        If the answer is not in the shared pages, say so instead of guessing. Use Markdown, but keep it light.
        In this chat you cannot open pages, search or click. If the user asks you to do something in the browser, tell them to switch the panel to Act mode (the Ask / Act switch at the top).
        """
    }

    /// The text a user turn is sent as: shared pages first, then the question.
    static func compose(_ question: String, contexts: [PageContext]) -> String {
        guard !contexts.isEmpty else { return question }
        var budget = totalLimit
        var parts: [String] = []
        for (i, c) in contexts.enumerated() {
            let page = c.trimmed(maxCharacters: min(perPageLimit, max(1_000, budget)))
            budget = max(0, budget - page.text.count)
            parts.append("<page index=\"\(i + 1)\" title=\"\(page.title.replacingOccurrences(of: "\"", with: "'"))\" url=\"\(page.url)\">\n\(page.text)\n</page>")
        }
        return parts.joined(separator: "\n\n") + "\n\nQuestion: " + question
    }

    public func send(_ question: String, contexts: [PageContext] = []) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return }
        guard let provider = providerFactory() else {
            messages.append(ChatMessage(role: .assistant, text: tr("Add an API key in Settings → Assistant to start."), isError: true))
            return
        }
        messages.append(ChatMessage(role: .user, text: q, sources: contexts.map(\.title), modelText: Self.compose(q, contexts: contexts)))
        let history = messages.map { LLMMessage(role: $0.role == .user ? "user" : "assistant", content: $0.modelText) }
        messages.append(ChatMessage(role: .assistant, text: ""))
        let replyIndex = messages.count - 1
        isStreaming = true
        task = Task { [weak self] in
            do {
                for try await chunk in provider.stream(system: Self.systemPrompt(), messages: history) {
                    guard let self, replyIndex < self.messages.count else { return }
                    self.messages[replyIndex].text += chunk
                    self.messages[replyIndex].modelText = self.messages[replyIndex].text
                }
            } catch is CancellationError {
            } catch {
                guard let self, replyIndex < self.messages.count else { return }
                let msg = (error as? AssistantError)?.message ?? error.localizedDescription
                if self.messages[replyIndex].text.isEmpty { self.messages[replyIndex].text = msg; self.messages[replyIndex].isError = true }
                else { self.messages.append(ChatMessage(role: .assistant, text: msg, isError: true)) }
            }
            self?.finish()
        }
    }

    private func finish() {
        isStreaming = false
        // An answer that never produced text (cancelled immediately) shouldn't leave an empty bubble.
        if let last = messages.last, last.role == .assistant, last.text.isEmpty { messages.removeLast() }
        task = nil
    }

    public func stop() { task?.cancel() }

    public func clear() {
        task?.cancel()
        messages.removeAll()
        isStreaming = false
    }
}

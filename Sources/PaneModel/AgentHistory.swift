import Foundation

/// One finished (or stopped) agent conversation, kept so it can be read again.
public struct AgentRunRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var title: String
    public var items: [AgentItem]
    public init(id: UUID, date: Date, title: String, items: [AgentItem]) { self.id = id; self.date = date; self.title = title; self.items = items }

    public var stepCount: Int { items.filter { if case .step = $0 { return true } else { return false } }.count }
}

/// The list of past agent conversations of one profile (newest first, at most 40). Stays on this Mac.
@MainActor
public final class AgentHistoryStore: ObservableObject {
    @Published public private(set) var runs: [AgentRunRecord] = []
    private let file: URL?
    private let limit = 40

    public init(directory: URL?) {
        file = directory?.appendingPathComponent("agent-history.json")
        if let file, let data = try? Data(contentsOf: file), let r = try? JSONDecoder().decode([AgentRunRecord].self, from: data) { runs = r }
    }

    public func upsert(_ run: AgentRunRecord) {
        var r = run
        // Keep the file small: long answers are cut.
        r.items = r.items.map { item in
            if case .assistant(let id, let t) = item, t.count > 4000 { return .assistant(id: id, text: String(t.prefix(4000)) + "…") }
            return item
        }
        runs.removeAll { $0.id == r.id }
        runs.insert(r, at: 0)
        if runs.count > limit { runs.removeLast(runs.count - limit) }
        persist()
    }

    public func remove(_ id: UUID) { runs.removeAll { $0.id == id }; persist() }
    public func clear() { runs.removeAll(); persist() }

    private func persist() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(runs) { try? data.write(to: file, options: .atomic) }
    }
}

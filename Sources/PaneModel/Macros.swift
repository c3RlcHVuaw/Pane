import Foundation

/// A request the user saved to run again with one click ("quick command").
public struct AgentMacro: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var prompt: String
    public init(id: UUID = UUID(), name: String, prompt: String) { self.id = id; self.name = name; self.prompt = prompt }
}

@MainActor
public final class MacroStore: ObservableObject {
    @Published public private(set) var macros: [AgentMacro] = []
    private let file: URL?

    public init(directory: URL?) {
        file = directory?.appendingPathComponent("macros.json")
        if let file, let data = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([AgentMacro].self, from: data) { macros = m }
    }

    @discardableResult
    public func add(name: String, prompt: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines), p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !p.isEmpty, n.count <= 40, macros.count < 30 else { return false }
        macros.append(AgentMacro(name: n, prompt: p)); persist()
        return true
    }

    public func remove(_ id: UUID) { macros.removeAll { $0.id == id }; persist() }

    private func persist() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(macros) { try? data.write(to: file, options: .atomic) }
    }
}

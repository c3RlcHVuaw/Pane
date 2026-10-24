import Foundation

public struct SavedSession: Codable, Identifiable, Equatable, Sendable {
    public struct Page: Codable, Equatable, Sendable { public var url: String; public var title: String
        public init(url: String, title: String) { self.url = url; self.title = title } }
    public var id = UUID()
    public var name: String
    public var date = Date()
    public var pages: [Page]
    public init(name: String, pages: [Page]) { self.name = name; self.pages = pages }
}

/// Named sets of tabs ("Thesis", "Renovation") to bring back with one click.
@MainActor
public final class SessionStore: ObservableObject {
    public static let shared = SessionStore()
    @Published public private(set) var sessions: [SavedSession] = []
    private var file: URL?

    public func configure(file: URL) {
        self.file = file
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([SavedSession].self, from: d) { sessions = s }
    }

    private func save() {
        guard let file, let d = try? JSONEncoder().encode(sessions) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: file, options: .atomic)
    }

    @discardableResult
    public func add(name: String, pages: [SavedSession.Page]) -> SavedSession? {
        let clean = pages.filter { $0.url.hasPrefix("http") }
        guard !clean.isEmpty else { return nil }
        let s = SavedSession(name: name, pages: clean)
        sessions.insert(s, at: 0); save()
        return s
    }
    public func remove(_ id: UUID) { sessions.removeAll { $0.id == id }; save() }
    public func session(_ id: UUID) -> SavedSession? { sessions.first { $0.id == id } }
}

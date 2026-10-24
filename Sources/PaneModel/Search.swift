import Foundation

public struct SearchItem: Sendable, Identifiable, Hashable {
    public enum Kind: Int, Sendable { case tab, bookmark, history }
    public var id: String
    public var kind: Kind
    public var title: String
    public var url: String
    public var tabID: UUID?
    public var lastUsed: Date?
    public var visits: Int

    public init(id: String, kind: Kind, title: String, url: String, tabID: UUID? = nil, lastUsed: Date? = nil, visits: Int = 0) {
        self.id = id; self.kind = kind; self.title = title; self.url = url
        self.tabID = tabID; self.lastUsed = lastUsed; self.visits = visits
    }

    public var host: String {
        guard let h = URL(string: url)?.host else { return url }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

public struct SearchHit: Sendable, Identifiable {
    public var item: SearchItem
    public var score: Double
    /// Found because it means something similar to the query, not because the words match.
    public var viaMeaning: Bool
    public var id: String { item.id }
    public init(item: SearchItem, score: Double, viaMeaning: Bool = false) {
        self.item = item; self.score = score; self.viaMeaning = viaMeaning
    }
}

/// Ranks tabs, bookmarks and history for the ⌘K palette. Implemented in PaneSearch.
public protocol SearchProvider: Sendable {
    /// Fast, synchronous word/prefix/fuzzy matching.
    func keywordSearch(_ query: String, in items: [SearchItem], limit: Int) -> [SearchHit]
    /// Slower matching by meaning; callers run it off the main thread.
    func semanticSearch(_ query: String, in items: [SearchItem], limit: Int) async -> [SearchHit]
}

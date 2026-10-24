import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var lastVisit: Date
    public var visits: Int
    /// A short piece of the page's own text (description, heading, first lines), so "that article about prices" can be found later. Stays on this Mac.
    public var snippet: String?

    public init(url: String, title: String, lastVisit: Date, visits: Int, snippet: String? = nil) {
        self.url = url; self.title = title; self.lastVisit = lastVisit; self.visits = visits; self.snippet = snippet
    }
}

/// Pages the user has loaded. Deduplicated by URL, capped, newest first.
@MainActor
public final class HistoryStore {
    public private(set) var entries: [HistoryEntry] = []
    public var onChange: (() -> Void)?
    private let limit: Int

    public init(limit: Int = 4000) { self.limit = limit }

    /// Records a visit. Ignores blank and non-web pages.
    public func record(url: String, title: String, at date: Date = Date()) {
        guard let u = URL(string: url), u.scheme == "http" || u.scheme == "https" else { return }
        let key = normalizedURL(url)
        if let i = entries.firstIndex(where: { normalizedURL($0.url) == key }) {
            var e = entries.remove(at: i)
            e.visits += 1; e.lastVisit = date
            if !title.isEmpty { e.title = title }
            entries.insert(e, at: 0)
        } else {
            entries.insert(HistoryEntry(url: url, title: title, lastVisit: date, visits: 1), at: 0)
            if entries.count > limit { entries.removeLast(entries.count - limit) }
        }
        onChange?()
    }

    /// Updates the title of an existing entry (titles often arrive after the visit is recorded).
    public func updateTitle(url: String, title: String) {
        let key = normalizedURL(url)
        guard !title.isEmpty, let i = entries.firstIndex(where: { normalizedURL($0.url) == key }), entries[i].title != title else { return }
        entries[i].title = title
        onChange?()
    }

    /// Attaches a text snippet to the visit of `url`.
    public func updateSnippet(url: String, snippet: String) {
        let key = normalizedURL(url)
        let s = String(snippet.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        guard !s.isEmpty, let i = entries.firstIndex(where: { normalizedURL($0.url) == key }), entries[i].snippet != s else { return }
        entries[i].snippet = s
        onChange?()
    }

    public func clear() { entries.removeAll(); onChange?() }
    public func remove(url: String) { entries.removeAll { $0.url == url }; onChange?() }

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(entries)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    public func load(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return false }
        entries = e
        return true
    }
}

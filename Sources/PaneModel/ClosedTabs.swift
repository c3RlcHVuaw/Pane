import Foundation

/// The last few closed tabs, so ⇧⌘T can bring them back.
public struct ClosedTabs: Sendable {
    public struct Entry: Equatable, Sendable {
        public var url: String
        public var title: String
        public var groupID: UUID?
        public init(url: String, title: String, groupID: UUID?) { self.url = url; self.title = title; self.groupID = groupID }
    }

    private(set) var entries: [Entry] = []
    private let limit: Int
    public init(limit: Int = 25) { self.limit = limit }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Remembers a closed tab. Blank start-page tabs aren't worth restoring.
    public mutating func push(_ e: Entry) {
        guard !e.url.isEmpty, e.url != "about:blank" else { return }
        entries.removeAll { $0.url == e.url }  // closing the same page twice shouldn't stack up
        entries.append(e)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    public mutating func pop() -> Entry? { entries.popLast() }
}

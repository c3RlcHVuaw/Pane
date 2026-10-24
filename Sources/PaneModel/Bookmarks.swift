import Foundation

public func normalizedURL(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
    while t.hasSuffix("/") { t.removeLast() }
    return t.lowercased()
}

/// A bookmark (has `url`) or a folder (no `url`).
public struct BookmarkNode: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: String?
    public var children: [BookmarkNode]

    public init(id: UUID = UUID(), title: String, url: String? = nil, children: [BookmarkNode] = []) {
        self.id = id; self.title = title; self.url = url; self.children = children
    }
    public static func folder(_ title: String, _ children: [BookmarkNode] = []) -> BookmarkNode {
        BookmarkNode(title: title, children: children)
    }
    public static func link(_ title: String, _ url: String) -> BookmarkNode { BookmarkNode(title: title, url: url) }

    public var isFolder: Bool { url == nil }
    public var displayTitle: String {
        if !title.isEmpty { return id == BookmarkStore.barID || id == BookmarkStore.otherID ? tr(title) : title }
        return url.flatMap { URL(string: $0)?.host } ?? url ?? tr("Untitled")
    }
    public var bookmarkCount: Int { isFolder ? children.reduce(0) { $0 + $1.bookmarkCount } : 1 }

    public func find(_ id: UUID) -> BookmarkNode? {
        if self.id == id { return self }
        for c in children { if let f = c.find(id) { return f } }
        return nil
    }

    public func find(url target: String) -> BookmarkNode? {
        let t = normalizedURL(target)
        if let u = url, normalizedURL(u) == t { return self }
        for c in children { if let f = c.find(url: target) { return f } }
        return nil
    }

    /// Removes the node with `id` from this subtree (not the receiver itself).
    @discardableResult
    public mutating func removeNode(_ id: UUID) -> BookmarkNode? {
        if let i = children.firstIndex(where: { $0.id == id }) { return children.remove(at: i) }
        for i in children.indices { if let r = children[i].removeNode(id) { return r } }
        return nil
    }

    @discardableResult
    public mutating func insert(_ node: BookmarkNode, into folder: UUID, before: UUID?) -> Bool {
        if id == folder, isFolder {
            if let b = before, let i = children.firstIndex(where: { $0.id == b }) { children.insert(node, at: i) }
            else { children.append(node) }
            return true
        }
        for i in children.indices where children[i].insert(node, into: folder, before: before) { return true }
        return false
    }

    @discardableResult
    public mutating func update(_ id: UUID, _ body: (inout BookmarkNode) -> Void) -> Bool {
        if self.id == id { body(&self); return true }
        for i in children.indices where children[i].update(id, body) { return true }
        return false
    }
}

/// Bookmarks tree with two fixed top-level folders: the bar and everything else.
@MainActor
public final class BookmarkStore {
    /// The two top-level folders have the same ids on every Mac, so synced items can name their parent.
    public nonisolated static let barID = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!
    public nonisolated static let otherID = UUID(uuidString: "00000000-0000-0000-0000-00000000B002")!

    public private(set) var bar = BookmarkNode(id: BookmarkStore.barID, title: "Bookmarks Bar")
    public private(set) var other = BookmarkNode(id: BookmarkStore.otherID, title: "Other Bookmarks")
    public var onChange: (() -> Void)?

    public init() {}

    public var roots: [BookmarkNode] { [bar, other] }
    public func node(_ id: UUID) -> BookmarkNode? { bar.find(id) ?? other.find(id) }
    public func bookmark(forURL url: String) -> BookmarkNode? { bar.find(url: url) ?? other.find(url: url) }
    public func isRoot(_ id: UUID) -> Bool { id == bar.id || id == other.id }
    public func isBookmarked(_ url: String) -> Bool { bookmark(forURL: url) != nil }

    // MARK: Editing

    @discardableResult
    public func add(title: String, url: String, toFolder folder: UUID? = nil, before: UUID? = nil) -> UUID {
        let n = BookmarkNode.link(title, url)
        insertNode(n, into: folder ?? bar.id, before: before)
        changed()
        return n.id
    }

    @discardableResult
    public func addFolder(_ title: String, in folder: UUID? = nil, before: UUID? = nil) -> UUID {
        let n = BookmarkNode.folder(title)
        insertNode(n, into: folder ?? other.id, before: before)
        changed()
        return n.id
    }

    /// Adds or removes the bookmark for `url`. Returns true when it ends up bookmarked.
    @discardableResult
    public func toggle(title: String, url: String) -> Bool {
        if let existing = bookmark(forURL: url) { remove(existing.id); return false }
        add(title: title, url: url)
        return true
    }

    public func remove(_ id: UUID) {
        guard !isRoot(id) else { return }
        if bar.removeNode(id) != nil || other.removeNode(id) != nil { changed() }
    }

    public func rename(_ id: UUID, to title: String) {
        guard !isRoot(id) else { return }
        if bar.update(id, { $0.title = title }) || other.update(id, { $0.title = title }) { changed() }
    }

    public func setURL(_ id: UUID, _ url: String) {
        if bar.update(id, { $0.url = url }) || other.update(id, { $0.url = url }) { changed() }
    }

    /// Moves a node into `folder` ahead of `before`. Refuses to move a folder into itself.
    @discardableResult
    public func move(_ id: UUID, toFolder folder: UUID, before: UUID? = nil) -> Bool {
        guard !isRoot(id), let node = self.node(id), id != before else { return false }
        if node.isFolder, node.find(folder) != nil { return false }
        guard let target = self.node(folder), target.isFolder else { return false }
        _ = bar.removeNode(id) ?? other.removeNode(id)
        insertNode(node, into: folder, before: before)
        changed()
        return true
    }

    /// Adds imported nodes as one new folder under "Other Bookmarks". Returns the number of bookmarks added.
    @discardableResult
    public func importTree(_ nodes: [BookmarkNode], folderName: String) -> Int {
        let folder = BookmarkNode.folder(folderName, nodes)
        guard folder.bookmarkCount > 0 else { return 0 }
        other.children.append(freshIDs(folder))
        changed()
        return folder.bookmarkCount
    }

    /// Replaces both folders with a merged tree (from sync). Keeps the fixed root ids.
    public func replaceRoots(bar newBar: BookmarkNode, other newOther: BookmarkNode) {
        var b = newBar, o = newOther
        b.id = Self.barID; o.id = Self.otherID
        guard b != bar || o != other else { return }
        bar = b; other = o
        changed()
    }

    private func freshIDs(_ n: BookmarkNode) -> BookmarkNode {
        BookmarkNode(title: n.title, url: n.url, children: n.children.map(freshIDs))
    }

    private func insertNode(_ n: BookmarkNode, into folder: UUID, before: UUID?) {
        if !bar.insert(n, into: folder, before: before), !other.insert(n, into: folder, before: before) {
            bar.children.append(n)
        }
    }

    // MARK: Persistence

    private struct Snapshot: Codable { var bar: BookmarkNode; var other: BookmarkNode }

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(Snapshot(bar: bar, other: other))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    public func load(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
        bar = s.bar; other = s.other
        bar.id = Self.barID; other.id = Self.otherID  // older files used random ids
        return true
    }

    private func changed() { onChange?() }
}

/// A source bookmarks can be imported from. Implemented in PaneImport; consumed by the UI.
public protocol BookmarkImporter: Sendable {
    var name: String { get }
    /// Files to try automatically, best guess first.
    func candidateFiles() -> [URL]
    /// Where an open panel should start when automatic access fails.
    var openPanelDirectory: URL { get }
    var openPanelMessage: String { get }
    func parse(_ data: Data) throws -> [BookmarkNode]
}

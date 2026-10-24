import Foundation
import PaneModel

public struct SyncRecord: Codable, Equatable, Sendable {
    public var id: String
    public var type: String       // "bookmark" | "folder" | "settings"
    public var payload: String    // canonical JSON; empty for tombstones
    public var updatedAt: Int64   // milliseconds since 1970
    public var deleted: Bool
    public var seq: Int?          // assigned by the server

    public init(id: String, type: String, payload: String, updatedAt: Int64, deleted: Bool = false, seq: Int? = nil) {
        self.id = id; self.type = type; self.payload = payload; self.updatedAt = updatedAt; self.deleted = deleted; self.seq = seq
    }
}

/// Bookmarks as flat, mergeable records: each node says who its parent is and where it sits.
enum BookmarkRecords {
    private struct Body: Codable { var p: String; var o: Int; var t: String; var u: String? }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    /// id → (type, canonical payload) for every bookmark and folder in both roots.
    static func records(bar: BookmarkNode, other: BookmarkNode) -> [String: (type: String, payload: String)] {
        var out: [String: (String, String)] = [:]
        func walk(_ node: BookmarkNode) {
            for (i, c) in node.children.enumerated() {
                let body = Body(p: node.id.uuidString, o: i, t: c.title, u: c.url)
                if let data = try? encoder.encode(body), let s = String(data: data, encoding: .utf8) {
                    out[c.id.uuidString] = (c.isFolder ? "folder" : "bookmark", s)
                }
                walk(c)
            }
        }
        walk(bar); walk(other)
        return out
    }

    /// Rebuilds both roots from the merged records. Items whose parent vanished land in "Other Bookmarks".
    static func tree(from records: [String: SyncRecord]) -> (bar: BookmarkNode, other: BookmarkNode) {
        struct Item { var id: String; var type: String; var body: Body }
        var items: [String: Item] = [:]
        let decoder = JSONDecoder()
        for r in records.values where !r.deleted && (r.type == "bookmark" || r.type == "folder") {
            guard UUID(uuidString: r.id) != nil, let b = try? decoder.decode(Body.self, from: Data(r.payload.utf8)) else { continue }
            items[r.id] = Item(id: r.id, type: r.type, body: b)
        }
        let rootIDs: Set<String> = [BookmarkStore.barID.uuidString, BookmarkStore.otherID.uuidString]
        var children: [String: [Item]] = [:]
        for it in items.values {
            let parentOK = rootIDs.contains(it.body.p) || items[it.body.p]?.type == "folder"
            children[parentOK ? it.body.p : BookmarkStore.otherID.uuidString, default: []].append(it)
        }
        var seen = Set<String>()
        func build(_ parent: String) -> [BookmarkNode] {
            (children[parent] ?? [])
                .sorted { ($0.body.o, $0.id) < ($1.body.o, $1.id) }
                .compactMap { it -> BookmarkNode? in
                    guard seen.insert(it.id).inserted, let uuid = UUID(uuidString: it.id) else { return nil }  // also breaks cycles
                    return it.type == "folder"
                        ? BookmarkNode(id: uuid, title: it.body.t, children: build(it.id))
                        : BookmarkNode(id: uuid, title: it.body.t, url: it.body.u ?? "")
                }
        }
        return (BookmarkNode(id: BookmarkStore.barID, title: "Bookmarks Bar", children: build(BookmarkStore.barID.uuidString)),
                BookmarkNode(id: BookmarkStore.otherID, title: "Other Bookmarks", children: build(BookmarkStore.otherID.uuidString)))
    }
}

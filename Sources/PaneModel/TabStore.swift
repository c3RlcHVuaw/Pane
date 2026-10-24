import Foundation

public struct TabItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    public var isPinned: Bool
    public var groupID: UUID?
    public var lastActive: Date
    public var isSleeping: Bool

    public init(id: UUID = UUID(), url: String, title: String = "", isPinned: Bool = false,
                groupID: UUID? = nil, lastActive: Date = Date(), isSleeping: Bool = false) {
        self.id = id; self.url = url; self.title = title; self.isPinned = isPinned
        self.groupID = groupID; self.lastActive = lastActive; self.isSleeping = isSleeping
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        return URL(string: url)?.host ?? (url.isEmpty ? tr("New Tab") : url)
    }
}

public struct TabGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var colorIndex: Int
    public var isCollapsed: Bool
    public init(id: UUID = UUID(), name: String, colorIndex: Int, isCollapsed: Bool = false) {
        self.id = id; self.name = name; self.colorIndex = colorIndex; self.isCollapsed = isCollapsed
    }
}

/// Pure tab/group model: ordering, pinning, groups, sleep. No engine or UI knowledge.
@MainActor
public final class TabStore {
    public private(set) var tabs: [TabItem] = []
    public private(set) var groups: [TabGroup] = []
    public private(set) var activeTabID: UUID?
    /// Structural changes: order, groups, pinning, sleep, active tab.
    public var onChange: (() -> Void)?
    /// A tab's title or URL changed. Cheap: observers refresh that one row instead of rebuilding the list.
    public var onTabUpdate: ((UUID) -> Void)?
    /// Something worth saving changed but nothing on screen needs rebuilding (e.g. a group was collapsed).
    public var onSilentChange: (() -> Void)?

    public init() {}

    // MARK: Queries

    public func tab(_ id: UUID) -> TabItem? { tabs.first { $0.id == id } }
    public func group(_ id: UUID) -> TabGroup? { groups.first { $0.id == id } }
    public var pinned: [TabItem] { tabs.filter { $0.isPinned } }
    public var ungrouped: [TabItem] { tabs.filter { !$0.isPinned && !$0.isSleeping && $0.groupID == nil } }
    public var sleeping: [TabItem] { tabs.filter { !$0.isPinned && $0.isSleeping && $0.groupID == nil } }
    public func tabs(in group: UUID) -> [TabItem] {
        tabs.filter { !$0.isPinned && $0.groupID == group }
    }

    // MARK: Tabs

    @discardableResult
    public func addTab(url: String, groupID: UUID? = nil, activate: Bool = true) -> UUID {
        let tab = TabItem(url: url, groupID: groupID.flatMap { group($0) == nil ? nil : $0 })
        tabs.append(tab)
        if activate || activeTabID == nil { self.activate(tab.id) } else { changed() }
        return tab.id
    }

    public func activate(_ id: UUID) {
        guard let i = index(id) else { return }
        if let prev = activeTabID, prev != id, let p = index(prev) { tabs[p].lastActive = Date() }
        tabs[i].lastActive = Date()
        tabs[i].isSleeping = false
        activeTabID = id
        changed()
    }

    /// Removes the tab. If it was active, the nearest remaining tab becomes active.
    public func close(_ id: UUID) {
        guard let i = index(id) else { return }
        tabs.remove(at: i)
        if activeTabID == id {
            let candidates = tabs.enumerated().filter { !$0.element.isSleeping }
            let next = candidates.first { $0.offset >= i } ?? candidates.last
            activeTabID = next?.element.id ?? tabs.first?.id
            if let a = activeTabID, let ai = index(a) { tabs[ai].isSleeping = false; tabs[ai].lastActive = Date() }
        }
        changed()
    }

    public func update(_ id: UUID, title: String? = nil, url: String? = nil) {
        guard let i = index(id) else { return }
        var did = false
        if let title, tabs[i].title != title { tabs[i].title = title; did = true }
        if let url, tabs[i].url != url { tabs[i].url = url; did = true }
        if did { onTabUpdate?(id) }
    }

    public func pin(_ id: UUID, before: UUID? = nil) {
        guard var t = remove(id) else { return }
        t.isPinned = true; t.groupID = nil; t.isSleeping = false
        insert(t, before: before)
        changed()
    }

    public func unpin(_ id: UUID) {
        guard let i = index(id) else { return }
        tabs[i].isPinned = false
        changed()
    }

    /// Moves a tab into a group (or out of all groups) ahead of `before`. Also wakes and unpins it.
    public func move(_ id: UUID, toGroup groupID: UUID?, before: UUID? = nil) {
        guard var t = remove(id) else { return }
        t.isPinned = false; t.isSleeping = false
        t.groupID = groupID.flatMap { group($0) == nil ? nil : $0 }
        insert(t, before: before == id ? nil : before)
        changed()
    }

    /// Returns false when the tab can't sleep (pinned, active, unknown).
    @discardableResult
    public func sleep(_ id: UUID) -> Bool {
        guard let i = index(id), !tabs[i].isPinned, activeTabID != id else { return false }
        tabs[i].isSleeping = true
        changed()
        return true
    }

    /// Puts tabs untouched for `interval` to sleep and returns their ids.
    @discardableResult
    public func sleepStale(olderThan interval: TimeInterval, now: Date = Date(), excluding keep: Set<UUID> = []) -> [UUID] {
        var slept: [UUID] = []
        for i in tabs.indices where !tabs[i].isPinned && !tabs[i].isSleeping && tabs[i].id != activeTabID && !keep.contains(tabs[i].id)
            && now.timeIntervalSince(tabs[i].lastActive) >= interval {
            tabs[i].isSleeping = true
            slept.append(tabs[i].id)
        }
        if !slept.isEmpty { changed() }
        return slept
    }

    // MARK: Groups

    @discardableResult
    public func createGroup(name: String, colorIndex: Int) -> UUID {
        let g = TabGroup(name: name, colorIndex: colorIndex)
        groups.append(g)
        changed()
        return g.id
    }

    public func renameGroup(_ id: UUID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = name; changed()
    }

    public func setGroupColor(_ id: UUID, colorIndex: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].colorIndex = colorIndex; changed()
    }

    public func setGroupCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let i = groups.firstIndex(where: { $0.id == id }), groups[i].isCollapsed != collapsed else { return }
        groups[i].isCollapsed = collapsed
        onSilentChange?()  // the outline already shows it; rebuilding the list mid-animation corrupts it
    }

    /// Deletes the group; its tabs become ungrouped.
    public func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        for i in tabs.indices where tabs[i].groupID == id { tabs[i].groupID = nil }
        changed()
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var tabs: [TabItem]; var groups: [TabGroup]; var activeTabID: UUID?
    }

    public func save(to url: URL, excluding: UUID? = nil) throws {
        let kept = tabs.filter { $0.id != excluding }
        let active = activeTabID.flatMap { id in kept.contains { $0.id == id } ? id : nil } ?? kept.first?.id
        let data = try JSONEncoder().encode(Snapshot(tabs: kept, groups: groups, activeTabID: active))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func load(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data), !snap.tabs.isEmpty else { return false }
        tabs = snap.tabs; groups = snap.groups
        activeTabID = snap.activeTabID.flatMap { id in snap.tabs.contains { $0.id == id } ? id : nil } ?? snap.tabs.first { !$0.isSleeping }?.id ?? snap.tabs[0].id
        return true
    }

    /// Replaces everything with the session saved at `url`, or with one fresh tab when there is none.
    /// Used when switching workspaces.
    public func replaceSession(from url: URL?, freshTabURL: String) {
        tabs = []; groups = []; activeTabID = nil
        if let url, load(from: url) { changed(); return }
        let t = TabItem(url: freshTabURL)
        tabs = [t]; activeTabID = t.id
        changed()
    }

    // MARK: Helpers

    private func index(_ id: UUID) -> Int? { tabs.firstIndex { $0.id == id } }
    private func remove(_ id: UUID) -> TabItem? { index(id).map { tabs.remove(at: $0) } }
    private func insert(_ t: TabItem, before: UUID?) {
        if let b = before, let bi = index(b) { tabs.insert(t, at: bi) } else { tabs.append(t) }
    }
    private func changed() { onChange?() }
}

import Foundation

/// A named set of tabs, pinned tabs and tab groups. Switching workspaces swaps the whole set.
public struct Workspace: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var colorIndex: Int
    public init(id: UUID = UUID(), name: String, colorIndex: Int) { self.id = id; self.name = name; self.colorIndex = colorIndex }
}

/// The list of workspaces of one profile. The first one ("Main") always exists and keeps the profile's original session file.
@MainActor
public final class WorkspaceStore {
    public static let mainID = UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!
    public private(set) var workspaces: [Workspace]
    public private(set) var activeID: UUID
    public var onChange: (() -> Void)?
    private let directory: URL?

    public init(directory: URL?) {
        self.directory = directory
        let main = Workspace(id: Self.mainID, name: "Main", colorIndex: 0)
        workspaces = [main]; activeID = Self.mainID
        if let d = directory, let data = try? Data(contentsOf: d.appendingPathComponent("workspaces.json")),
           let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.workspaces.contains(where: { $0.id == Self.mainID }) {
            workspaces = saved.workspaces
            activeID = saved.workspaces.contains { $0.id == saved.activeID } ? saved.activeID : Self.mainID
        }
    }

    private struct Saved: Codable { var workspaces: [Workspace]; var activeID: UUID }

    public var active: Workspace { workspaces.first { $0.id == activeID } ?? workspaces[0] }
    public var hasMany: Bool { workspaces.count > 1 }

    /// Where a workspace keeps its tabs. Main uses the profile's ordinary session file.
    public func sessionURL(for id: UUID) -> URL? {
        guard let directory else { return nil }
        return directory.appendingPathComponent(id == Self.mainID ? "session.json" : "session-\(id.uuidString).json")
    }

    @discardableResult
    public func add(name: String) -> Workspace? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 40, !workspaces.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) else { return nil }
        let w = Workspace(name: n, colorIndex: workspaces.count)
        workspaces.append(w); persist(); onChange?()
        return w
    }

    public func rename(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 40, let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].name = n; persist(); onChange?()
    }

    public func setColor(_ id: UUID, _ colorIndex: Int) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].colorIndex = colorIndex; persist(); onChange?()
    }

    /// Removes a workspace and its saved tabs. The main one can't be removed.
    public func remove(_ id: UUID) {
        guard id != Self.mainID, let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces.remove(at: i)
        if let u = sessionURL(for: id) { try? FileManager.default.removeItem(at: u) }
        if activeID == id { activeID = Self.mainID }
        persist(); onChange?()
    }

    public func activate(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }), id != activeID else { return }
        activeID = id; persist(); onChange?()
    }

    public func workspace(named name: String) -> Workspace? {
        workspaces.first { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
    }

    private func persist() {
        guard let d = directory else { return }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Saved(workspaces: workspaces, activeID: activeID)) {
            try? data.write(to: d.appendingPathComponent("workspaces.json"), options: .atomic)
        }
    }
}

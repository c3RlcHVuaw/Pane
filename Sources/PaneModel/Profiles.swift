import Combine
import Foundation

public struct ProfileInfo: Codable, Identifiable, Equatable, Sendable {
    /// Folder name under Profiles/; never changes, even if the profile is renamed.
    public var id: String
    public var name: String
    public var colorIndex: Int
    public init(id: String, name: String, colorIndex: Int) { self.id = id; self.name = name; self.colorIndex = colorIndex }
}

/// Extra browsing profiles (Work, School, …). The built-in profile isn't listed here; each extra one has
/// its own tabs, bookmarks, history, logins and cookies.
@MainActor
public final class ProfilesStore: ObservableObject {
    @Published public private(set) var profiles: [ProfileInfo] = []
    public var onChange: (() -> Void)?
    public static let maxNameLength = 30

    public init() {}

    public static func slug(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let s = folded.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        let collapsed = s.replacingOccurrences(of: "-+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "profile" : collapsed
    }

    public func isNameTaken(_ name: String, except id: String? = nil) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return n == "default" || profiles.contains { $0.id != id && $0.name.lowercased() == n }
    }

    /// Returns nil for an empty, too long or already used name.
    @discardableResult
    public func add(name: String, colorIndex: Int) -> ProfileInfo? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.count <= Self.maxNameLength, !isNameTaken(n) else { return nil }
        let base = Self.slug(from: n)
        var id = base, i = 2
        while id == "default" || profiles.contains(where: { $0.id == id }) { id = "\(base)-\(i)"; i += 1 }
        let p = ProfileInfo(id: id, name: n, colorIndex: colorIndex)
        profiles.append(p)
        onChange?()
        return p
    }

    @discardableResult
    public func rename(_ id: String, to name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard let i = profiles.firstIndex(where: { $0.id == id }), !n.isEmpty, n.count <= Self.maxNameLength, !isNameTaken(n, except: id) else { return false }
        profiles[i].name = n
        onChange?()
        return true
    }

    public func setColor(_ id: String, colorIndex: Int) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].colorIndex = colorIndex
        onChange?()
    }

    public func remove(_ id: String) { profiles.removeAll { $0.id == id }; onChange?() }
    public func profile(_ id: String) -> ProfileInfo? { profiles.first { $0.id == id } }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(profiles).write(to: url, options: .atomic)
    }

    @discardableResult
    public func load(from url: URL) -> Bool {
        guard let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([ProfileInfo].self, from: d) else { return false }
        profiles = p
        return true
    }
}

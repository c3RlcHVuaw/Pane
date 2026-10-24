import Foundation

/// One line of the release history shown in Settings → Updates.
public struct ReleaseEntry: Codable, Identifiable, Equatable, Sendable {
    public var version: String
    public var build: Int
    public var date: String
    public var notes: String
    public var id: Int { build }
    public init(version: String, build: Int, date: String, notes: String) { self.version = version; self.build = build; self.date = date; self.notes = notes }

    /// The notes as separate points.
    public var points: [String] { WhatsNew.lines(from: notes) }
}

/// The list of every release and what changed in it, fetched next to the update feed (cached for offline use).
public enum ReleaseHistory {
    private static let cacheKey = "releaseHistoryCache"

    public static func load(feedURL: URL, defaults: UserDefaults = .standard) async -> [ReleaseEntry] {
        let url = feedURL.deletingLastPathComponent().appendingPathComponent("releases.json")
        if let (data, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
           let list = try? JSONDecoder().decode([ReleaseEntry].self, from: data), !list.isEmpty {
            defaults.set(data, forKey: cacheKey)
            return list.sorted { $0.build > $1.build }
        }
        if let data = defaults.data(forKey: cacheKey), let list = try? JSONDecoder().decode([ReleaseEntry].self, from: data) { return list.sorted { $0.build > $1.build } }
        return []
    }
}

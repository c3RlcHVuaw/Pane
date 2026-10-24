import Foundation

/// What the new-tab page shows: your bookmarks bar first, then the sites you visit most, then what you saw last.
public enum StartPageContent {
    public struct Site: Equatable, Sendable, Identifiable {
        public var id: String { url }
        public var title: String
        public var url: String
    }

    private static func host(_ url: String) -> String {
        let h = URL(string: url)?.host?.lowercased() ?? url
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    public static func favorites(bar: [BookmarkNode], history: [HistoryEntry], limit: Int = 8) -> [Site] {
        var out: [Site] = []
        var hosts = Set<String>()
        func add(_ title: String, _ url: String) {
            guard out.count < limit, hosts.insert(host(url)).inserted else { return }
            out.append(Site(title: title.isEmpty ? host(url) : title, url: url))
        }
        for n in bar { if let u = n.url { add(n.displayTitle, u) } }
        for e in history.sorted(by: { ($0.visits, $0.lastVisit) > ($1.visits, $1.lastVisit) }) where e.visits >= 2 { add(e.title, e.url) }
        return out
    }

    /// Latest visits, one per site, skipping anything already shown as a favorite.
    public static func recents(history: [HistoryEntry], excluding favorites: [Site], limit: Int = 6) -> [Site] {
        var hosts = Set(favorites.map { host($0.url) })
        var out: [Site] = []
        for e in history.sorted(by: { $0.lastVisit > $1.lastVisit }) {
            guard out.count < limit, hosts.insert(host(e.url)).inserted else { continue }
            out.append(Site(title: e.title.isEmpty ? host(e.url) : e.title, url: e.url))
        }
        return out
    }

    public static func greeting(at date: Date = Date(), calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: return tr("Good morning")
        case 12..<18: return tr("Good afternoon")
        case 18..<23: return tr("Good evening")
        default: return tr("Good night")
        }
    }
}

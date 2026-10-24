import Foundation

/// What the search engine itself suggests while you type in the address bar.
public enum WebSuggestions {
    /// The suggestion address of an engine, or nil when it has none.
    static func endpoint(engineID: String, query: String) -> URL? {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let s: String?
        switch engineID {
        case "google": s = "https://suggestqueries.google.com/complete/search?client=firefox&q=\(q)"
        case "duckduckgo": s = "https://duckduckgo.com/ac/?type=list&q=\(q)"
        case "yandex": s = "https://suggest.yandex.ru/suggest-ff.cgi?part=\(q)"
        case "bing": s = "https://api.bing.com/osjson.aspx?query=\(q)"
        case "brave": s = "https://search.brave.com/api/suggest?q=\(q)"
        default: s = nil
        }
        return s.flatMap(URL.init(string:))
    }

    /// OpenSearch-style answer: ["query", ["a", "b", …]].
    public static func parse(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count > 1, let list = json[1] as? [Any] else { return [] }
        return list.compactMap { $0 as? String }
    }

    public static func fetch(_ query: String, engineID: String) async -> [String] {
        guard query.count >= 2, let url = endpoint(engineID: engineID, query: query) else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return [] }
        return Array(parse(data).filter { $0.caseInsensitiveCompare(query) != .orderedSame }.prefix(5))
    }
}

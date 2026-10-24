import Foundation

/// "Tell me when this page says X." Checked in the background every half hour while Pane is open.
public struct PageWatch: Codable, Identifiable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case appears, disappears, changes, below, above }
    public var id: UUID
    public var url: String
    public var text: String          // what to look for (empty for `changes`)
    public var mode: Mode
    public var title: String
    public var baseline: String?     // for `changes`: fingerprint of the page when the watch began
    public var threshold: Double?    // for `below` / `above`: the number to compare with (the first number after `text`)
    public var lastChecked: Date?
    public var triggered: Bool
    public init(id: UUID = UUID(), url: String, text: String, mode: Mode, title: String, baseline: String? = nil,
                lastChecked: Date? = nil, triggered: Bool = false, threshold: Double? = nil) {
        self.threshold = threshold
        self.id = id; self.url = url; self.text = text; self.mode = mode; self.title = title
        self.baseline = baseline; self.lastChecked = lastChecked; self.triggered = triggered
    }
}

public enum WatchChecker {
    /// The visible text of an HTML document: scripts, styles and tags removed, whitespace collapsed.
    public static func plainText(fromHTML html: String) -> String {
        var s = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<!--[\\s\\S]*?-->", "<[^>]+>"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] { s = s.replacingOccurrences(of: a, with: b) }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func fingerprint(_ text: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in text.lowercased().utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }

    /// Downloads the page and returns its plain text, or nil when it can't be read.
    public static func fetchText(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { return nil }
        let html = String(data: data.prefix(2_000_000), encoding: .utf8) ?? String(decoding: data.prefix(2_000_000), as: UTF8.self)
        return plainText(fromHTML: html)
    }

    /// The first number that follows `keyword` (within 80 characters), reading "1 299,50", "1,299.50" and "49 990" correctly.
    /// With an empty keyword, the first number on the page.
    public static func number(after keyword: String, in text: String) -> Double? {
        var scope = Substring(text)
        if !keyword.isEmpty {
            guard let r = text.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            scope = text[r.upperBound...].prefix(80)
        }
        guard let m = scope.range(of: "[0-9][0-9 \\u{00A0}\\u{202F}.,]*[0-9]|[0-9]", options: .regularExpression) else { return nil }
        var s = String(scope[m]).filter { !" \u{00A0}\u{202F}".contains($0) }
        // The last separator is the decimal point only if 1–2 digits follow it.
        if let last = s.lastIndex(where: { $0 == "." || $0 == "," }) {
            let digitsAfter = s.distance(from: last, to: s.endIndex) - 1
            let head = s[..<last].filter { $0 != "." && $0 != "," }
            s = digitsAfter <= 2 ? head + "." + s[s.index(after: last)...] : head + s[s.index(after: last)...]
        }
        return Double(s)
    }

    /// Whether the watch's condition holds for this page text.
    public static func isMet(_ w: PageWatch, pageText: String) -> Bool {
        switch w.mode {
        case .appears: return pageText.range(of: w.text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .disappears: return pageText.range(of: w.text, options: [.caseInsensitive, .diacriticInsensitive]) == nil
        case .changes: return w.baseline != nil && fingerprint(pageText) != w.baseline
        case .below, .above:
            guard let t = w.threshold, let n = number(after: w.text, in: pageText) else { return false }
            return w.mode == .below ? n < t : n > t
        }
    }
}

@MainActor
public final class WatchStore: ObservableObject {
    @Published public private(set) var watches: [PageWatch] = []
    private let file: URL?
    public var onTriggered: ((PageWatch) -> Void)?

    public init(directory: URL?) {
        file = directory?.appendingPathComponent("watches.json")
        if let file, let data = try? Data(contentsOf: file), let w = try? JSONDecoder().decode([PageWatch].self, from: data) { watches = w }
    }

    public func add(_ w: PageWatch) -> Bool {
        guard watches.count < 20 else { return false }
        watches.append(w); persist(); return true
    }
    public func remove(_ id: UUID) { watches.removeAll { $0.id == id }; persist() }

    /// Checks every active watch once. Triggered watches stop (they have done their job).
    public func checkAll(now: Date = Date()) async {
        for w in watches where !w.triggered {
            guard let text = await WatchChecker.fetchText(w.url) else { continue }
            guard let i = watches.firstIndex(where: { $0.id == w.id }) else { continue }
            watches[i].lastChecked = now
            if watches[i].mode == .changes, watches[i].baseline == nil { watches[i].baseline = WatchChecker.fingerprint(text) }
            else if WatchChecker.isMet(watches[i], pageText: text) {
                watches[i].triggered = true
                onTriggered?(watches[i])
            }
        }
        persist()
    }

    private func persist() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(watches) { try? data.write(to: file, options: .atomic) }
    }
}

import Foundation
import PaneModel

/// Turns whatever the user typed into a loadable URL string.
public enum AddressInput {
    /// True when the text is a URL or host rather than a search phrase.
    public static func looksLikeAddress(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.contains("://") || t.hasPrefix("about:") || (!t.contains(" ") && (t.contains(".") || t.hasPrefix("localhost")))
    }

    public static func resolve(_ raw: String, engine: SearchEngine = .named("google")) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("://") || t.hasPrefix("about:") || t.hasPrefix("data:") { return t }
        let looksLikeHost = !t.contains(" ") && (t.contains(".") || t.hasPrefix("localhost"))
        if looksLikeHost { return "https://" + t }
        return engine.url(for: t)
    }
}

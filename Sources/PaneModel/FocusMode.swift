import Foundation

public enum FocusSites {
    public static let defaults = "youtube.com, twitter.com, x.com, instagram.com, facebook.com, tiktok.com, reddit.com, vk.com, twitch.tv, netflix.com"

    public static func list(_ text: String) -> [String] {
        text.split(whereSeparator: { ",; \n".contains($0) }).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// True when `host` is one of the listed sites or a subdomain of one.
    public static func isBlocked(host: String, in sites: [String]) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return sites.contains { h == $0 || h.hasSuffix("." + $0) }
    }
}

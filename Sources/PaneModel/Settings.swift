import Combine
import Foundation

public struct SearchEngine: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// Query template; `%s` is replaced by the percent-encoded search text.
    public let template: String
    public let home: String

    public func url(for query: String) -> String {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26").replacingOccurrences(of: "+", with: "%2B") ?? query
        return template.replacingOccurrences(of: "%s", with: q)
    }

    public static let all: [SearchEngine] = [
        SearchEngine(id: "google", name: "Google", template: "https://www.google.com/search?q=%s", home: "https://www.google.com"),
        SearchEngine(id: "duckduckgo", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s", home: "https://duckduckgo.com"),
        SearchEngine(id: "yandex", name: "Yandex", template: "https://yandex.com/search/?text=%s", home: "https://yandex.com"),
        SearchEngine(id: "bing", name: "Bing", template: "https://www.bing.com/search?q=%s", home: "https://www.bing.com"),
        SearchEngine(id: "brave", name: "Brave Search", template: "https://search.brave.com/search?q=%s", home: "https://search.brave.com"),
        SearchEngine(id: "startpage", name: "Startpage", template: "https://www.startpage.com/do/search?q=%s", home: "https://www.startpage.com"),
        SearchEngine(id: "ecosia", name: "Ecosia", template: "https://www.ecosia.org/search?q=%s", home: "https://www.ecosia.org"),
    ]
    public static func named(_ id: String) -> SearchEngine { all.first { $0.id == id } ?? all[0] }
}

public enum StartupBehavior: String, CaseIterable, Sendable, Identifiable {
    case restore, newTab
    public var id: String { rawValue }
    public var title: String { self == .restore ? tr("Continue where I left off") : tr("Open a new tab") }
}

public enum NewTabPage: String, CaseIterable, Sendable, Identifiable {
    case startPage, searchEngine, blank, custom
    public var id: String { rawValue }
    public var title: String {
        switch self { case .startPage: tr("Start page"); case .searchEngine: tr("Search engine home"); case .blank: tr("Blank page"); case .custom: tr("Custom address") }
    }
}

public enum AppearanceChoice: String, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String { tr(rawValue == "system" ? "Match System" : rawValue == "light" ? "Light" : "Dark") }
}

/// User preferences, persisted in UserDefaults. SwiftUI binds to the published properties;
/// the browser reacts through `onChange`.
@MainActor
public final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    /// Called with the key that changed, after it was saved.
    public var onChange: ((String) -> Void)?

    @Published public var searchEngineID: String { didSet { save("searchEngine", searchEngineID) } }
    @Published public var startup: StartupBehavior { didSet { save("startup", startup.rawValue) } }
    @Published public var newTabPage: NewTabPage { didSet { save("newTabPage", newTabPage.rawValue) } }
    @Published public var customNewTabURL: String { didSet { save("customNewTabURL", customNewTabURL) } }
    /// Minutes of inactivity before a tab sleeps; 0 means never.
    @Published public var sleepMinutes: Int { didSet { save("sleepMinutes", sleepMinutes) } }
    @Published public var appearance: AppearanceChoice { didSet { save("appearance", appearance.rawValue) } }
    @Published public var showBookmarksBar: Bool { didSet { save("showBookmarksBar", showBookmarksBar) } }
    /// Facts the agent may use to fill in forms and applications. Stays on this Mac (never synced).
    @Published public var aboutMe: String { didSet { save("aboutMe", aboutMe) } }
    /// Keep a short snippet of each visited page for "find that article" searches. Local only.
    @Published public var rememberPageText: Bool { didSet { save("rememberPageText", rememberPageText) } }
    /// The agent works in a private tab and can't see bookmarks, history, notes or saved logins.
    @Published public var agentPrivate: Bool { didSet { save("agentPrivate", agentPrivate) } }
    /// Ask the search engine for suggestions while typing in the address bar.
    @Published public var webSuggestions: Bool { didSet { save("webSuggestions", webSuggestions) } }
    /// Two-finger swipe goes back and forward.
    @Published public var swipeNavigation: Bool { didSet { save("swipeNavigation", swipeNavigation) } }
    @Published public var appIcon: String { didSet { save("appIcon", appIcon) } }
    @Published public var hapticFeedback: Bool { didSet { save("hapticFeedback", hapticFeedback) } }
    @Published public var theme: ThemeChoice { didSet { save("theme", theme.rawValue) } }
    @Published public var offerToSavePasswords: Bool { didSet { save("offerToSavePasswords", offerToSavePasswords) } }
    @Published public var sidebarTint: Bool { didSet { save("sidebarTint", sidebarTint) } }
    @Published public var blockAds: Bool { didSet { save("blockAds", blockAds) } }
    @Published public var automaticUpdates: Bool { didSet { save("automaticUpdates", automaticUpdates) } }
    /// "anthropic" or "openai" (any OpenAI-compatible endpoint). The key itself lives in the Keychain.
    @Published public var assistantProvider: String { didSet { save("assistantProvider", assistantProvider) } }
    @Published public var assistantModel: String { didSet { save("assistantModel", assistantModel) } }
    @Published public var assistantBaseURL: String { didSet { save("assistantBaseURL", assistantBaseURL) } }
    /// Ask before the agent does anything risky (closing tabs, changing settings, submitting forms). Never synced.
    @Published public var agentConfirm: Bool { didSet { save("agentConfirm", agentConfirm) } }
    /// Act mode (the assistant controls the browser). Off until switched on in Settings → Assistant.
    @Published public var agentEnabled: Bool { didSet { save("agentEnabled", agentEnabled) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        searchEngineID = defaults.string(forKey: "searchEngine") ?? "google"
        startup = StartupBehavior(rawValue: defaults.string(forKey: "startup") ?? "") ?? .restore
        newTabPage = NewTabPage(rawValue: defaults.string(forKey: "newTabPage") ?? "") ?? .startPage
        customNewTabURL = defaults.string(forKey: "customNewTabURL") ?? ""
        sleepMinutes = defaults.object(forKey: "sleepMinutes") as? Int ?? 30
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        showBookmarksBar = defaults.object(forKey: "showBookmarksBar") as? Bool ?? true
        automaticUpdates = defaults.object(forKey: "automaticUpdates") as? Bool ?? true
        blockAds = defaults.object(forKey: "blockAds") as? Bool ?? true
        sidebarTint = defaults.object(forKey: "sidebarTint") as? Bool ?? true
        offerToSavePasswords = defaults.object(forKey: "offerToSavePasswords") as? Bool ?? true
        aboutMe = defaults.string(forKey: "aboutMe") ?? ""
        rememberPageText = defaults.object(forKey: "rememberPageText") as? Bool ?? true
        agentPrivate = defaults.object(forKey: "agentPrivate") as? Bool ?? false
        webSuggestions = defaults.object(forKey: "webSuggestions") as? Bool ?? true
        swipeNavigation = defaults.object(forKey: "swipeNavigation") as? Bool ?? true
        appIcon = defaults.string(forKey: "appIcon") ?? "original"
        hapticFeedback = defaults.object(forKey: "hapticFeedback") as? Bool ?? true
        theme = ThemeChoice(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        assistantProvider = defaults.string(forKey: "assistantProvider") ?? "anthropic"
        assistantModel = defaults.string(forKey: "assistantModel") ?? "claude-sonnet-5-5"
        assistantBaseURL = defaults.string(forKey: "assistantBaseURL") ?? ""
        agentConfirm = defaults.object(forKey: "agentConfirm") as? Bool ?? true
        agentEnabled = defaults.object(forKey: "agentEnabled") as? Bool ?? true
    }

    public var searchEngine: SearchEngine { SearchEngine.named(searchEngineID) }

    /// Address a new tab loads. Empty means Pane's own start page (no web page is loaded).
    public var newTabURL: String {
        switch newTabPage {
        case .startPage: return ""
        case .searchEngine: return searchEngine.home
        case .blank: return "about:blank"
        case .custom:
            let t = customNewTabURL.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return searchEngine.home }
            return t.contains("://") ? t : "https://" + t
        }
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        onChange?(key)
    }

    // Values worth carrying to other Macs.
    public var syncable: [String: String] {
        ["searchEngine": searchEngineID, "newTabPage": newTabPage.rawValue, "customNewTabURL": customNewTabURL,
         "appearance": appearance.rawValue, "sleepMinutes": String(sleepMinutes)]
    }

    public func applySynced(_ values: [String: String]) {
        if let v = values["searchEngine"], SearchEngine.all.contains(where: { $0.id == v }), v != searchEngineID { searchEngineID = v }
        if let v = values["newTabPage"], let e = NewTabPage(rawValue: v), e != newTabPage { newTabPage = e }
        if let v = values["customNewTabURL"], v != customNewTabURL { customNewTabURL = v }
        if let v = values["appearance"], let e = AppearanceChoice(rawValue: v), e != appearance { appearance = e }
        if let v = values["sleepMinutes"], let n = Int(v), n != sleepMinutes { sleepMinutes = n }
    }
}

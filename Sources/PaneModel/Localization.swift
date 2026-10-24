import Foundation

/// Looks a message up in the app's Localizable.strings (Russian today); falls back to the English text itself.
/// Use for text that is built at run time. For fixed text with interpolation prefer `String(localized:)`.
public func tr(_ english: String) -> String {
    Bundle.main.localizedString(forKey: english, value: english, table: nil)
}

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, english, russian
    public var id: String { rawValue }
    public var code: String? { switch self { case .system: nil; case .english: "en"; case .russian: "ru" } }
    /// Shown in its own language so it can always be found.
    public var title: String { switch self { case .system: tr("System"); case .english: "English"; case .russian: "Русский" } }

    /// The language the app launched in (what the bundle resolved to).
    public static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }
    public static var currentLocale: Locale { Locale(identifier: current) }

    /// What the user chose: the first entry of the app-specific AppleLanguages list, if there is one.
    public static var chosen: AppLanguage {
        guard let list = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String], let first = list.first, !isSystemWide(list) else { return .system }
        return first.hasPrefix("ru") ? .russian : (first.hasPrefix("en") ? .english : .system)
    }

    private static func isSystemWide(_ list: [String]) -> Bool {
        // When nothing app-specific is set, AppleLanguages mirrors the global list.
        let global = UserDefaults(suiteName: UserDefaults.globalDomain)?.array(forKey: "AppleLanguages") as? [String]
        return global == list
    }

    /// What was chosen when this run started (used to tell whether a restart is pending).
    public static let chosenAtLaunch: AppLanguage = chosen

    /// Takes effect on the next launch.
    public static func choose(_ l: AppLanguage) {
        if let code = l.code { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
        else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
    }
}

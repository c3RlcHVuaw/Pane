import Foundation
import PaneModel

/// What a browser window is for.
public enum WindowKind {
    /// The built-in profile.
    case standard
    /// An extra profile with its own tabs, bookmarks, history and logins.
    case profile(ProfileInfo)
    /// Nothing is remembered: no session, history or cookies once the window closes.
    case privateSession

    public var isPrivate: Bool { if case .privateSession = self { return true }; return false }
    public var profileInfo: ProfileInfo? { if case .profile(let p) = self { return p }; return nil }
}

/// Where one profile's files live. Private windows have none.
public struct WindowStorage {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public var session: URL { directory.appendingPathComponent("session.json") }
    public var bookmarks: URL { directory.appendingPathComponent("bookmarks.json") }
    public var history: URL { directory.appendingPathComponent("history.json") }
    public var downloads: URL { directory.appendingPathComponent("downloads.json") }
    public var favicons: URL { directory.appendingPathComponent("Favicons") }
}

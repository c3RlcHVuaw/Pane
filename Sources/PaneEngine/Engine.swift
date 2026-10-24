import AppKit

/// Engine-agnostic abstractions. The UI layer talks only to these; the CEF layer implements them.
@MainActor
public protocol BrowserTabDelegate: AnyObject {
    func tab(_ tab: BrowserTab, didChangeTitle title: String)
    func tab(_ tab: BrowserTab, didChangeURL url: String)
    func tab(_ tab: BrowserTab, loadingChanged state: LoadingState)
    func tab(_ tab: BrowserTab, didChangeFavicon image: NSImage)
    func tab(_ tab: BrowserTab, requestsNewTabWith url: String)
    func tab(_ tab: BrowserTab, audioChanged isPlaying: Bool)
    func tab(_ tab: BrowserTab, downloadUpdated info: DownloadInfo)
    /// Result of a find-in-page: total matches and the 1-based index of the highlighted one.
    func tab(_ tab: BrowserTab, findResultCount count: Int, active: Int)
    /// Text the page shows for the link under the pointer; empty when nothing is hovered.
    func tab(_ tab: BrowserTab, statusChanged text: String)
    /// The page's process died. `reason` reads like "crashed" or "ran out of memory".
    func tab(_ tab: BrowserTab, processTerminated reason: String)
    /// A message from Pane's own page script (see PasswordScripts). The text starts with "__pane:".
    func tab(_ tab: BrowserTab, didSendPageMessage message: String)
}

public struct PageError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct DownloadInfo: Sendable, Equatable {
    public enum State: Sendable { case inProgress, complete, canceled }
    public var id: Int
    public var name: String
    public var path: String
    /// 0...100, or -1 when the size isn't known.
    public var percent: Int
    public var received: Int64
    public var total: Int64
    public var state: State
    public init(id: Int, name: String, path: String, percent: Int, received: Int64, total: Int64, state: State) {
        self.id = id; self.name = name; self.path = path; self.percent = percent
        self.received = received; self.total = total; self.state = state
    }
}

public struct LoadingState: Sendable, Equatable {
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public init(isLoading: Bool = false, canGoBack: Bool = false, canGoForward: Bool = false) {
        self.isLoading = isLoading; self.canGoBack = canGoBack; self.canGoForward = canGoForward
    }
}

@MainActor
public protocol BrowserTab: AnyObject {
    var delegate: BrowserTabDelegate? { get set }
    func load(_ url: String)
    func goBack()
    func goForward()
    func reload()
    func stop()
    /// Hidden tabs keep their state but stop rendering.
    func setHidden(_ hidden: Bool)
    /// Zoom by `steps` (positive in, negative out); `resetZoom` returns to 100%.
    func zoom(by steps: Double)
    func resetZoom()
    /// Chromium's logarithmic zoom level: 0 is 100%, each step multiplies by 1.2.
    func zoomLevel() -> Double
    func setMuted(_ muted: Bool)
    /// The page's visible text, for sharing with the assistant. Empty if the page can't be read.
    func pageText() async -> String
    func find(_ text: String, forward: Bool, matchCase: Bool, next: Bool)
    func stopFinding()
    func cancelDownload(id: Int)
    func printPage()
    /// Sends a Chrome DevTools Protocol command to the page and returns its result JSON.
    func devTools(_ method: String, params: String?) async throws -> String
    func savePDF(to url: URL) async -> Bool
    /// Closes the page. `onClosed` runs once the engine has let go of the view it was given, which is when that view may be removed.
    func close(onClosed: @escaping @MainActor () -> Void)
}

/// Where tabs keep their cookies, storage and cache. Tabs sharing a profile share logins; different profiles never do.
@MainActor
public final class BrowserProfile {
    public enum Kind: Hashable, Sendable {
        case standard
        case named(String)
        /// Nothing is kept: storage lives in memory and disappears with the window.
        case privateSession
    }
    public let kind: Kind
    /// The engine's own object for this profile, created on first use.
    public var engineHandle: AnyObject?
    public init(_ kind: Kind) { self.kind = kind }
    public static let standard = BrowserProfile(.standard)
}

@MainActor
public protocol BrowserEngine: AnyObject {
    /// Creates a tab whose page view is installed as a child of `host`.
    func makeTab(url: String, in host: NSView, profile: BrowserProfile) -> BrowserTab
    func shutdown()
    /// Blocks requests to known ad and tracker hosts.
    func setContentBlocking(_ on: Bool)
}

import AppKit
import CEFBridge
import PaneEngine

@MainActor
public final class CEFEngine: BrowserEngine {
    private let cacheRoot: URL

    public init?(cacheDirectory: URL, languages: [String] = ProcessInfo.processInfo.environment["PANE_LANGS"].map { $0.components(separatedBy: ",") } ?? ["en-US"]) {
        cacheRoot = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard PCRuntime.initialize(withCachePath: cacheDirectory.path, languages: languages) else { return nil }
    }

    public func makeTab(url: String, in host: NSView, profile: BrowserProfile) -> BrowserTab {
        if profile.engineHandle == nil {
            switch profile.kind {
            case .standard: break  // the engine's default context
            case .named(let id): profile.engineHandle = PCContext(atPath: cacheRoot.appendingPathComponent("Profiles/\(id)").path)
            case .privateSession: profile.engineHandle = PCContext.private()
            }
        }
        return CEFTab(url: url, host: host, context: profile.engineHandle as? PCContext)
    }

    public func shutdown() { PCRuntime.shutdown() }
    public func setContentBlocking(_ on: Bool) { PCRuntime.setAdBlocking(on) }
    public func clearCookies(for url: String, profile: BrowserProfile) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            PCRuntime.clearCookies(for: url, in: profile.engineHandle as? PCContext) { c.resume() }
        }
    }
    public func clearBrowsingData(for profile: BrowserProfile) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            PCRuntime.clearBrowsingData(in: profile.engineHandle as? PCContext) { c.resume() }
        }
    }
}

/// Resumes a continuation exactly once, whichever of "text arrived" and "timed out" comes first.
@MainActor
private final class Once {
    private var continuation: CheckedContinuation<String, Never>?
    init(_ c: CheckedContinuation<String, Never>) { continuation = c }
    func finish(_ s: String) { continuation?.resume(returning: s); continuation = nil }
}

@MainActor
final class CEFTab: NSObject, BrowserTab, PCBrowserDelegate {
    weak var delegate: BrowserTabDelegate?
    private let browser: PCBrowser
    private var state = LoadingState()

    init(url: String, host: NSView, context: PCContext?) {
        browser = PCBrowser(url: url, parent: host, context: context)
        super.init()
        browser.delegate = self
    }

    func load(_ url: String) { browser.loadURL(url) }
    func goBack() { browser.goBack() }
    func goForward() { browser.goForward() }
    func reload() { state.isLoading ? browser.stopLoading() : browser.reload() }
    func stop() { browser.stopLoading() }
    func close(onClosed: @escaping @MainActor () -> Void) { browser.close { Task { @MainActor in onClosed() } } }
    func setHidden(_ hidden: Bool) { browser.setHidden(hidden) }
    func zoom(by steps: Double) { browser.zoom(by: steps, reset: false) }
    func resetZoom() { browser.zoom(by: 0, reset: true) }
    func find(_ text: String, forward: Bool, matchCase: Bool, next: Bool) { browser.findText(text, forward: forward, matchCase: matchCase, next: next) }
    func stopFinding() { browser.stopFinding() }
    func zoomLevel() -> Double { browser.zoomLevel() }
    func setMuted(_ muted: Bool) { browser.setMuted(muted) }

    func pageText() async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            let once = Once(c)
            browser.fetchText { text in Task { @MainActor in once.finish(text) } }
            Task { @MainActor in try? await Task.sleep(nanoseconds: 4_000_000_000); once.finish("") }  // a dead page must not hang the assistant
        }
    }
    func cancelDownload(id: Int) { browser.cancelDownload(UInt32(id)) }
    func printPage() { browser.printPage() }
    func showDevTools() { browser.showDevTools() }
    func performEdit(_ command: EditCommand) { browser.performEdit(command.rawValue) }
    func downloadURL(_ url: String) { browser.downloadURL(url) }
    func replaceMisspelling(_ word: String) { browser.replaceMisspelling(word) }
    func addToDictionary(_ word: String) { browser.add(toDictionary: word) }

    func devTools(_ method: String, params: String?) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            browser.devToolsMethod(method, params: params) { result, error in
                if let result { c.resume(returning: result) } else { c.resume(throwing: PageError(error ?? "Failed.")) }
            }
        }
    }
    func savePDF(to url: URL) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            browser.savePDF(toPath: url.path) { ok in c.resume(returning: ok) }
        }
    }

    func browserDidChangeTitle(_ title: String) { delegate?.tab(self, didChangeTitle: title) }
    func browserDidChangeURL(_ url: String) { delegate?.tab(self, didChangeURL: url) }
    func browserLoadingChanged(_ loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        state = LoadingState(isLoading: loading, canGoBack: canGoBack, canGoForward: canGoForward)
        delegate?.tab(self, loadingChanged: state)
    }
    func browserDidCreateView(_ view: NSView) {}
    func browserDidChangeFavicon(_ image: NSImage) { delegate?.tab(self, didChangeFavicon: image) }
    func browserAudioChanged(_ playing: Bool) { delegate?.tab(self, audioChanged: playing) }
    func browserDownloadUpdated(_ downloadID: UInt32, name: String, path: String, percent: Int, received: Int64, total: Int64, state: Int) {
        let s: DownloadInfo.State = state == 1 ? .inProgress : (state == 2 ? .complete : .canceled)
        delegate?.tab(self, downloadUpdated: DownloadInfo(id: Int(downloadID), name: name, path: path, percent: percent,
                                                          received: received, total: total, state: s))
    }
    func browserFindResultCount(_ count: Int, active: Int) { delegate?.tab(self, findResultCount: count, active: active) }
    func browserStatusChanged(_ text: String) { delegate?.tab(self, statusChanged: text) }
    func browserPageMessage(_ message: String) { delegate?.tab(self, didSendPageMessage: message) }
    func browserRequestsPermission(_ origin: String, kinds: [String], decision: @escaping (Bool) -> Void) {
        delegate?.tab(self, requestsPermission: origin, kinds: kinds) { decision($0) } ?? decision(false)
    }
    func browserRequestsLogin(_ host: String, realm: String, isProxy: Bool, completion: @escaping (String?, String?) -> Void) {
        delegate?.tab(self, requestsLoginFor: host, realm: realm, isProxy: isProxy) { completion($0, $1) } ?? completion(nil, nil)
    }
    func browserCertificateProblem(_ url: String, reason: String, proceed: @escaping (Bool) -> Void) {
        delegate?.tab(self, certificateProblemFor: url) { proceed($0) } ?? proceed(false)
    }
    func browserFullscreenChanged(_ on: Bool) { delegate?.tab(self, fullscreenChanged: on) }
    func browserShowsContextMenu(_ info: [AnyHashable: Any]) {
        func str(_ k: String) -> String { info[k] as? String ?? "" }
        delegate?.tab(self, showsContextMenu: ContextMenuInfo(
            link: str("link"), linkText: str("linkText"), mediaSource: str("source"), media: (info["media"] as? String).flatMap(ContextMenuInfo.Media.init(rawValue:)),
            selection: str("selection"), isEditable: info["editable"] as? Bool ?? false, hasLink: info["hasLink"] as? Bool ?? false,
            misspelledWord: str("misspelled"), suggestions: info["suggestions"] as? [String] ?? [], pageURL: str("page")))
    }
    func browserRenderProcessTerminated(_ reason: String) { delegate?.tab(self, processTerminated: reason) }
    func browserRequestsNewTab(_ url: String) { delegate?.tab(self, requestsNewTabWith: url) }
}

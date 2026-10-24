import AppKit
import PaneEngine
import PaneModel
import ScreenCaptureKit
@preconcurrency import UserNotifications
import SwiftUI

/// Thin draggable strip between sidebar and content.
@MainActor
final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.deltaX) }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
public final class BrowserWindowController: NSWindowController, NSTextFieldDelegate, BrowserTabDelegate, NSWindowDelegate, TabCommands {
    struct Live {
        let tab: BrowserTab; let container: NSView
        /// Edge constraints; the "half" ones are used while two pages share the window (split view).
        let leading: NSLayoutConstraint, trailing: NSLayoutConstraint, halfLeading: NSLayoutConstraint, halfTrailing: NSLayoutConstraint
    }

    private let engine: BrowserEngine
    let settings: AppSettings
    private let profiles: ProfilesStore
    private let appActions: AppActions
    private let account: AccountSession
    public let updateStatus = UpdateStatus()
    private var settingsWindow: SettingsWindowController?
    private var shortcutsOverlay: ShortcutsOverlayView?
    public let kind: WindowKind
    private let storage: WindowStorage?
    private let profile: BrowserProfile
    /// Set on every window but the first: Settings is one shared window, owned by the first.
    public var settingsRouter: (() -> Void)?
    public var onClosed: (() -> Void)?
    public var isPrivate: Bool { kind.isPrivate }
    private let sleepOverride: TimeInterval?
    private let importers: [BookmarkImporter]
    let search: SearchProvider
    private let updater: AppUpdater?
    private var updateButton: NSButton!
    private var updateSlotHeight: NSLayoutConstraint!
    private var userCheckPending = false
    let history = HistoryStore()
    private var historySaveWork: DispatchWorkItem?
    private var palette: CommandPaletteView?
    private var rootView: NSView!
    let store = TabStore()
    let bookmarks: BookmarkStore
    private weak var syncScheduler: SyncScheduler?
    private let faviconCache: FaviconCache
    private var bookmarksSaveWork: DispatchWorkItem?
    var live: [UUID: Live] = [:]
    private var tabIDs: [ObjectIdentifier: UUID] = [:]
    private var favicons: [UUID: NSImage] = [:]
    var navState: [UUID: LoadingState] = [:]
    private var audible: Set<UUID> = []
    private var crashOverlays: [UUID: NSView] = [:]
    private let downloads = DownloadsStore()
    private var isLoaded = false
    private var downloadsButton: NSButton!
    private var downloadsPopover: NSPopover?
    private var downloadsSaveWork: DispatchWorkItem?
    private var findBar: FindBarView?
    private let assistantSession: AssistantSession
    private let assistantKey: KeychainSecretStore
    private var assistantModel: AssistantPanelModel!
    private var assistantWidth: NSLayoutConstraint!
    private var assistantButton: NSButton!
    private var columnLeading: NSLayoutConstraint!
    private var edgeHover: HoverBox!
    private var peeking = false
    private var peekWork: DispatchWorkItem?
    private var assistantOpen = false
    private var gatheringForAssistant = false
    private var closedTabs = ClosedTabs()
    // The agent (see Agent/AgentToolbox.swift)
    var agent: AgentSession!
    let agentProviderFactory: () -> AgentProvider?
    var agentOverlay: AgentOverlayView!
    var agentPill: AgentStatusPill!
    var agentRefs: [Int: AgentRef] = [:]
    var agentTabNumbers: [UUID: Int] = [:]
    var agentBookmarkNumbers: [Int: UUID] = [:]
    var agentWatchNumbers: [Int: UUID] = [:]
    /// In private-agent mode: the one tab the agent works in (a private context, kept out of history and saved sessions).
    var agentPrivateTabID: UUID?
    private let agentPrivateProfile = BrowserProfile(.privateSession)
    var agentIsolated: Bool { settings.agentPrivate }

    /// Makes sure the agent's private tab exists and is the one on screen.
    func prepareAgentPrivateTab() {
        if let id = agentPrivateTabID, store.tab(id) != nil {
            if store.activeTabID != id { store.activate(id) }
            return
        }
        agentPrivateTabID = store.addTab(url: "about:blank", activate: true)
        showActive()
    }

    func closeAgentPrivateTab() {
        guard let id = agentPrivateTabID else { return }
        agentPrivateTabID = nil
        destroyLive(id)
        store.close(id)
        if store.tabs.isEmpty { store.addTab(url: settings.newTabURL) }
    }
    /// Pages the user asked to be told about (checked in the background every half hour).
    lazy var watches: WatchStore = {
        let s = WatchStore(directory: storage?.directory)
        s.onTriggered = { [weak self] w in self?.watchTriggered(w) }
        return s
    }()
    private var watchTimer: Timer?
    var debugForceAct = false
    private var muted: Set<UUID> = []
    private let suggestions = AddressSuggestionsView()
    private var isFullScreen = false
    private let startModel = StartPageModel()
    private var startHost: StartPageHostingView!
    private var sleepTimer: Timer?
    private var saveWork: DispatchWorkItem?

    let webHost = WebHostView()
    private let addressField = AddressField()
    private let lockIcon = NSImageView()
    private let loadingBar = LoadingBar()
    private let statusBubble = StatusBubble()
    private var addressPill: NSView!
    private var addressFull = ""
    private var isEditingAddress = false
    private var contrastObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var sidebar: TabSidebarView!
    private var bookmarksSidebar: BookmarksSidebarView!
    private var bookmarksBar: BookmarksBarView!
    private var modeControl: NSSegmentedControl!
    private var starButton: NSButton!
    private var barGlass: NSView!
    private var barHeight: NSLayoutConstraint!
    private var barTop: NSLayoutConstraint!
    private var webTop: NSLayoutConstraint!
    private var bookmarksBarVisible = true
    private var back: NSButton!, forward: NSButton!, reloadButton: NSButton!
    private var sidebarWidth: NSLayoutConstraint!
    private var sidebarSurface: NSView?
    private var windowGlass: NSView?
    private var tintedFor: UUID?
    /// The page shown beside the active one (split view), if any.
    private var splitID: UUID?
    private var shownActiveID: UUID?
    private var sidebarContentWidth: NSLayoutConstraint!
    private var barLeading: NSLayoutConstraint!
    private var resizeHandle: SidebarResizeHandle!
    private var assistantResizeHandle: SidebarResizeHandle!
    private var expandedWidth: CGFloat = 250
    private var sidebarCollapsed = false

    private enum Defaults { static let width = "sidebarWidth", collapsed = "sidebarCollapsed", bookmarksBar = "bookmarksBarVisible" }

    public init(engine: BrowserEngine, settings: AppSettings, account: AccountSession, profiles: ProfilesStore, appActions: AppActions, kind: WindowKind, storage: WindowStorage?,
                importers: [BookmarkImporter], search: SearchProvider, updater: AppUpdater? = nil,
                bookmarks: BookmarkStore, syncScheduler: SyncScheduler? = nil, assistant: AssistantSession, assistantKey: KeychainSecretStore,
                agentProvider: @escaping () -> AgentProvider?, sleepOverride: TimeInterval? = nil) {
        self.engine = engine
        self.agentProviderFactory = agentProvider
        self.assistantSession = assistant
        self.assistantKey = assistantKey
        self.bookmarks = bookmarks
        self.syncScheduler = syncScheduler
        self.settings = settings
        self.profiles = profiles
        self.appActions = appActions
        self.account = account
        self.search = search
        self.updater = updater
        self.kind = kind
        self.storage = storage
        self.importers = importers
        self.faviconCache = FaviconCache(directory: storage?.favicons)  // private windows keep icons in memory only
        switch kind {
        case .standard: self.profile = BrowserProfile(.standard)
        case .profile(let p): self.profile = BrowserProfile(.named(p.id))
        case .privateSession: self.profile = BrowserProfile(.privateSession)
        }
        self.sleepOverride = sleepOverride
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 720, height: 460)
        // A test instance must never write window positions into the real app's preferences.
        let testMode = ProcessInfo.processInfo.environment["PANE_OFFSCREEN"] != nil || ProcessInfo.processInfo.environment["PANE_SUPPORT_DIR"] != nil
        switch kind {
        case _ where testMode: break
        case .standard: window.setFrameAutosaveName("PaneMainWindow")
        case .profile(let p): window.setFrameAutosaveName("PaneWindow-\(p.id)")
        case .privateSession: window.setFrameOrigin(NSPoint(x: 120 + Int.random(in: 0...80), y: 120 + Int.random(in: 0...80)))
        }
        super.init(window: window)
        window.delegate = self
        agent = AgentSession(toolbox: self, providerFactory: agentProviderFactory)
        agent.confirmImportantActions = settings.agentConfirm
        agent.userDetails = { [weak self] in (self?.settings.agentPrivate ?? false) ? "" : (self?.settings.aboutMe ?? "") }
        agent.extraInstructions = { [weak self] in
            (self?.settings.agentPrivate ?? false) ? "\n\nPRIVATE MODE: you work in one private tab. You can't see the user's other tabs, bookmarks, history, notes, saved logins or settings, and you can't change them. Use only the page tools; navigate always opens in your private tab." : ""
        }
        agent.onCleared = { [weak self] in self?.closeAgentPrivateTab() }
        let d = UserDefaults.standard
        if d.object(forKey: Defaults.width) != nil { expandedWidth = min(max(CGFloat(d.double(forKey: Defaults.width)), 190), 380) }
        sidebarCollapsed = d.bool(forKey: Defaults.collapsed)
        bookmarksBarVisible = settings.showBookmarksBar
        buildInterface(in: window)
        if window.frameAutosaveName.isEmpty { window.center() }
        keepWindowOnScreen()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    public func start() {
        defer { showWhatsNewIfNeeded(); startWatching(); installSwipeNavigation() }
        if syncScheduler != nil { vault.onChange = { [weak self] in self?.syncScheduler?.scheduleSync() } }
        engine.setContentBlocking(settings.blockAds)
        engine.setDocumentStartScript(NotificationShim.script(decisions: notificationDecisions))
        let restored = sessionURL.map { store.load(from: $0) } ?? false
        if !restored { store.addTab(url: settings.newTabURL) }
        else if settings.startup == .newTab { store.addTab(url: settings.newTabURL) }
        applyAppearance()
        applyTheme()
        updater?.automaticChecks = settings.automaticUpdates
        store.onChange = { [weak self] in self?.modelChanged() }
        store.onTabUpdate = { [weak self] id in self?.sidebar.refreshTab(id); self?.scheduleSave() }
        store.onSilentChange = { [weak self] in self?.scheduleSave() }
        if let s = storage { bookmarks.load(from: s.bookmarks); history.load(from: s.history); downloads.load(from: s.downloads) }
        downloads.onChange = { [weak self] in self?.downloadsChanged() }
        updateDownloadsButton()
        history.onChange = { [weak self] in self?.scheduleHistorySave(); if self?.startHost.isHidden == false { self?.refreshStartPage() } }
        bookmarks.onChange = { [weak self] in self?.bookmarksChanged() }
        showWindow(nil)
        window?.layoutIfNeeded()
        alignTrafficLights()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.alignTrafficLights() } }
        sidebar.reload()
        bookmarksBar.reload()
        bookmarksSidebar.reload()
        showActive()
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebar.reload(); self?.bookmarksBar.reload(); self?.bookmarksSidebar.reload() }
        }
        if let updater {
            updater.onChange = { [weak self] s in self?.updateStateChanged(s) }
            updater.start()
        }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: sleepOverride.map { min(60, max(1, $0 / 2)) } ?? 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepStaleTabs() }
        }
        // Coming back to the app is a good moment to look for an update.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.settings.automaticUpdates == true { self?.updater?.checkNow(userInitiated: false) } }
        }
    }

    // MARK: Settings

    /// The app tells every window when a preference changes.
    public func settingChanged(_ key: String) {
        switch key {
        case "appearance": applyAppearance(); syncScheduler?.scheduleSync()
        case "showBookmarksBar": if settings.showBookmarksBar != bookmarksBarVisible { setBookmarksBar(visible: settings.showBookmarksBar) }
        case "automaticUpdates": updater?.automaticChecks = settings.automaticUpdates
        case "searchEngine", "newTabPage", "customNewTabURL", "sleepMinutes": syncScheduler?.scheduleSync()
        case "assistantProvider", "assistantModel", "assistantBaseURL": refreshAssistantModel()
        case "agentConfirm": agent.confirmImportantActions = settings.agentConfirm; assistantModel?.autoApprove = !settings.agentConfirm
        case "agentEnabled": refreshAssistantModel()
        case "blockAds": engine.setContentBlocking(settings.blockAds)
        case "sidebarTint": updateSidebarTint()
        case "theme": applyTheme()
        case "agentPrivate": assistantModel?.agentPrivate = settings.agentPrivate; if !settings.agentPrivate { closeAgentPrivateTab() }
        default: break
        }
    }

    private func applyAppearance() {
        guard ProcessInfo.processInfo.environment["PANE_APPEARANCE"] == nil else { return }
        switch settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @objc public func showSettings(_ sender: Any?) {
        if let route = settingsRouter { route(); return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                settings: settings, account: account, updates: updateStatus, profiles: profiles, app: appActions,
                actions: SettingsActions(
                    checkForUpdates: { [weak self] in self?.updater?.checkNow(userInitiated: true) },
                    installUpdate: { [weak self] in self?.updater?.install() },
                    clearHistory: { [weak self] in self?.history.clear() },
                    historyCount: { [weak self] in self?.history.entries.count ?? 0 },
                    hasAssistantKey: { [weak self] in self?.assistantKey.hasValue ?? false },
                    saveAssistantKey: { [weak self] k in self?.assistantKey.save(k); self?.refreshAssistantModel() },
                    clearAssistantKey: { [weak self] in self?.assistantKey.clear(); self?.refreshAssistantModel() },
                    testAssistant: { [weak self] in await self?.testAssistantConnection() ?? (false, "") },
                    vault: vault,
                    clearBrowsingData: { [weak self] in
                        guard let self else { return }
                        await self.engine.clearBrowsingData(for: self.profile)
                        self.liveTabsReload()
                    },
                    isDefaultBrowser: {
                        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
                        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
                    },
                    makeDefaultBrowser: {
                        for scheme in ["http", "https"] { NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in } }
                    },
                    releaseHistory: { [weak self] in
                        let feed = ProcessInfo.processInfo.environment["PANE_UPDATE_FEED"] ?? (Bundle.main.infoDictionary?["PaneUpdateFeed"] as? String) ?? ""
                        guard self != nil, let url = URL(string: feed) else { return [] }
                        return await ReleaseHistory.load(feedURL: url)
                    },
                    openPage: { [weak self] url in self?.open(url, newTab: true) },
                    showHistory: { [weak self] in self?.showHistory(nil) },
                    notificationDecisions: { [weak self] in self?.notificationDecisions ?? [:] },
                    setNotificationDecision: { [weak self] origin, value in
                        guard let self else { return }
                        var all = self.notificationDecisions; all[origin] = value; self.notificationDecisions = all
                    }))
        }
        settingsWindow?.show()
    }

    /// Debug aid: draws a window's views into a PNG (no screen-recording permission needed).
    public func debugSnapshot(_ which: String, to path: String) {
        let w: NSWindow? = which == "settings" ? settingsWindow?.window : window
        guard let view = w?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    public func debugOpenShortcuts() { toggleShortcuts(nil) }

    /// Debug aid: opens the panel in Act mode, approves risky steps automatically (or not), and starts the agent.
    public func debugAgent(task: String, autoApprove: Bool) {
        debugForceAct = true
        if !assistantOpen { toggleAssistant(nil) }
        assistantModel.agentEnabled = true
        assistantModel.mode = .act
        agent.send(task)
        if autoApprove {
            Task { @MainActor [weak self] in
                while let self, self.agent.isRunning {
                    if self.agent.pendingApproval != nil { self.agent.answer(approve: true) }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
    }

    /// Debug aid: which view would receive a click in the middle of the page, and what sits above/below it.
    /// Debug aid: shows the first toolbar button in its hovered state.
    public func debugHoverToolbar() {}

    /// Debug aid: opens and closes the assistant panel and flips Ask/Act repeatedly, to shake out layout loops.
    public func debugStressPanel(times: Int) {
        Task { @MainActor [weak self] in
            for i in 0..<times {
                guard let self else { return }
                self.toggleAssistant(nil)
                self.assistantModel.mode = i % 2 == 0 ? .act : .ask
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }

    /// Debug aid: hammers tabs, groups, sleep, split view, workspaces, the assistant panel and the sidebar, then reports whether it all held up.
    public func debugStressEverything(rounds: Int) async -> String {
        let pages = ["http://127.0.0.1:8765/form.html", "http://127.0.0.1:8765/ads.html", "http://127.0.0.1:8765/login.html", "https://en.wikipedia.org/wiki/Web_browser"]
        var log = ""
        for r in 0..<rounds {
            var ids: [UUID] = []
            for i in 0..<8 { ids.append(store.addTab(url: pages[(r + i) % pages.count], activate: true)); showActive(); try? await Task.sleep(nanoseconds: 150_000_000) }
            let g = store.createGroup(name: "G\(r)", colorIndex: r)
            for id in ids.prefix(4) { store.move(id, toGroup: g) }
            for id in ids.suffix(2) { store.pin(id) }
            for id in ids.prefix(3) { _ = store.sleep(id); destroyLive(id) }
            toggleSplit(nil); try? await Task.sleep(nanoseconds: 300_000_000); toggleSplit(nil)
            toggleAssistant(nil); try? await Task.sleep(nanoseconds: 350_000_000); toggleAssistant(nil)
            store.setGroupCollapsed(g, true); sidebar.reload()
            if let w = workspaces.add(name: "S\(r)") { switchWorkspace(w.id); try? await Task.sleep(nanoseconds: 300_000_000); switchWorkspace(WorkspaceStore.mainID); workspaces.remove(w.id) }
            for id in ids { if store.tab(id) != nil { store.close(id); destroyLive(id) } }
            store.deleteGroup(g)
            showActive()
            log += "round \(r): tabs=\(store.tabs.count) live=\(live.count)\n"
        }
        return log + "survived"
    }

    /// Debug aid: hammers the sidebar with random moves, groups, pins, sleeps and closes at different speeds.
    public func debugSidebarStress(steps: Int) async -> String {
        var rng = SystemRandomNumberGenerator()
        var made = 0
        for step in 0..<steps {
            let tabs = store.tabs
            let op = Int.random(in: 0..<9, using: &rng)
            if ProcessInfo.processInfo.environment["PANE_DEBUG_SIDEBAR_LOG"] != nil { NSLog("sidebar step \(step) op \(op) tabs \(tabs.count)") }
            switch op {
            case 0, 1:
                store.addTab(url: "about:blank#\(step)", activate: false); made += 1
            case 2:
                if store.groups.count < 4 { store.createGroup(name: "G\(step)", colorIndex: step) }
            case 3:
                if let t = tabs.randomElement(using: &rng), let g = store.groups.randomElement(using: &rng) { store.move(t.id, toGroup: g.id) }
            case 4:
                if let t = tabs.randomElement(using: &rng) { store.move(t.id, toGroup: nil, before: tabs.randomElement(using: &rng)?.id) }
            case 5:
                if let t = tabs.randomElement(using: &rng) { t.isPinned ? store.unpin(t.id) : store.pin(t.id) }
            case 6:
                if let t = tabs.randomElement(using: &rng), t.id != store.activeTabID { _ = store.sleep(t.id) }
            case 7:
                if tabs.count > 3, let t = tabs.randomElement(using: &rng) { store.close(t.id); destroyLive(t.id); showActive() }
            default:
                if let g = store.groups.randomElement(using: &rng) { if Bool.random() { store.deleteGroup(g.id) } else { store.setGroupCollapsed(g.id, !g.isCollapsed); sidebar.reload() } }
            }
            try? await Task.sleep(nanoseconds: UInt64([0, 20, 60, 160].randomElement(using: &rng)!) * 1_000_000)
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        return "sidebar survived: steps=\(steps) tabs=\(store.tabs.count) groups=\(store.groups.count) made=\(made)"
    }

    /// Debug aid: feeds absurdly long text to every place that shows page-controlled text.
    public func debugLongStrings(_ parts: Set<String>) {
        let long = String(repeating: "https://example.com/very/long/path/", count: 120)
        if parts.contains("addr") { addressField.stringValue = long }
        if parts.contains("status") { statusBubble.set(long) }
        if parts.contains("title"), let id = store.activeTabID { store.update(id, title: long, url: long); sidebar.refreshTab(id) }
        if parts.contains("toast") { ToastView.show(in: webHost, message: long, symbol: "link", actionTitle: "Open", duration: 60) }
        if parts.contains("tabs") { for i in 0..<30 { store.addTab(url: "https://e.com/\(i)", activate: false); store.update(store.tabs.last!.id, title: long) } }
        if parts.contains("group") { let g = store.createGroup(name: long, colorIndex: 0); store.move(store.tabs.last!.id, toGroup: g) }
    }

    /// Debug aid: exercises the features that are hard to see in a still picture and reports what happened.
    public func debugFeatures() async -> String {
        var out: [String] = []
        // Star bounce: bookmark a page and let the symbol effect run.
        store.addTab(url: "http://127.0.0.1:8765/ads.html", activate: true); showActive()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        bookmarkThisPage(nil)
        try? await Task.sleep(nanoseconds: 700_000_000)
        out.append("star pulse ran, bookmarked=\(bookmarks.isBookmarked("http://127.0.0.1:8765/ads.html"))")
        for _ in 0..<10 where history.entries.first(where: { $0.url.contains("ads.html") })?.snippet == nil { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        out.append("history snippet: \(history.entries.first { $0.url.contains("ads.html") }?.snippet ?? "none")")
        if let tab = activeLive?.tab, let raw = try? await tab.devTools("Page.captureSnapshot", params: "{\"format\":\"mhtml\"}"), let d = raw.data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let text = o["data"] as? String { out.append("mhtml: \(text.hasPrefix("From:") || text.contains("MIME-Version") ? "ok" : "odd") \(text.count) chars") } else { out.append("mhtml: failed") }
        let suggest = await WebSuggestions.fetch("swift prog", engineID: "google")
        out.append("web suggestions: \(suggest.isEmpty ? "none (offline?)" : "ok \(suggest.count)")")
        // Sidebar tint colour from an icon.
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in NSColor.systemOrange.setFill(); r.fill(); return true }
        out.append("dominant colour of an orange icon: \(DominantColor.of(img).map { "h=\(Int($0.hueComponent * 360)) s=\(String(format: "%.2f", $0.saturationComponent))" } ?? "none")")
        let grey = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in NSColor.gray.setFill(); r.fill(); return true }
        out.append("dominant colour of a grey icon: \(DominantColor.of(grey) == nil ? "none (as expected)" : "unexpected")")
        // Page watch end to end: a text that is on the page triggers it.
        var fired: String?
        watches.onTriggered = { w in fired = w.title }
        _ = watches.add(PageWatch(url: "http://127.0.0.1:8765/ads.html", text: "control: pending", mode: .appears, title: "ads page"))
        _ = watches.add(PageWatch(url: "http://127.0.0.1:8765/ads.html", text: "this text is not there", mode: .appears, title: "absent"))
        await watches.checkAll()
        out.append("watch fired for: \(fired ?? "nothing"); still waiting: \(watches.watches.filter { !$0.triggered }.map(\.title))")
        // Reader mode on a real article page.
        return out.joined(separator: "\n")
    }

    /// Debug aid: opens a handful of pages, waits, then quits the way ⌘Q does.
    public func debugQuitAfterOpening(_ pages: Int) async {
        let urls = ["http://127.0.0.1:8765/form.html", "http://127.0.0.1:8765/ads.html", "https://en.wikipedia.org/wiki/Web_browser", "http://127.0.0.1:8765/login.html"]
        for i in 0..<pages { store.addTab(url: urls[i % urls.count], activate: true); showActive(); try? await Task.sleep(nanoseconds: 300_000_000) }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        try? "\(Date().timeIntervalSince1970)".write(toFile: ProcessInfo.processInfo.environment["PANE_DEBUG_QUIT_FILE"] ?? NSTemporaryDirectory() + "pane-quit-start.txt", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    /// Debug aid: translates a French test page and reports the result, then restores it.
    public func debugTranslate() async -> String {
        store.addTab(url: "http://127.0.0.1:8765/fr.html", activate: true); showActive()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let tab = activeLive?.tab else { return "no tab" }
        func text() async -> String { await tab.pageText() }
        let before = await text()
        let outcome = await translator.toggle(on: tab, into: "Russian") { _, _ in }
        let after = await text()
        let back = await translator.toggle(on: tab, into: "Russian") { _, _ in }
        let restored = await text()
        return "before: \(before)\n\noutcome: \(outcome)\nafter: \(after)\n\nrestore: \(back)\nrestored == before: \(restored == before)"
    }

    public func debugFullscreen() async -> String {
        store.addTab(url: "http://127.0.0.1:8765/video.html", activate: true); showActive()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let tab = activeLive?.tab, let id = store.activeTabID else { return "no tab" }
        func eval(_ js: String) async -> String {
            let p = try? JSONSerialization.data(withJSONObject: ["expression": js, "awaitPromise": true, "userGesture": true, "returnByValue": true])
            return (try? await tab.devTools("Runtime.evaluate", params: p.flatMap { String(data: $0, encoding: .utf8) })) ?? "error"
        }
        var out = ""
        out += "request: " + (await eval("document.documentElement.requestFullscreen().then(() => 'ok', e => 'denied:' + e.name)")) + "\n"
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        out += "in fullscreen: window=\(window?.styleMask.contains(.fullScreen) == true) host=\(fullscreenHost != nil) containerParentIsHost=\(live[id]?.container.superview === fullscreenHost) size=\(Int(live[id]?.container.frame.width ?? 0))x\(Int(live[id]?.container.frame.height ?? 0))\n"
        out += "exit: " + (await eval("document.exitFullscreen().then(() => 'ok', e => 'denied:' + e.name)")) + "\n"
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        out += "after exit: window=\(window?.styleMask.contains(.fullScreen) == true) host=\(fullscreenHost != nil) containerParentIsWebHost=\(live[id]?.container.superview === webHost) size=\(Int(live[id]?.container.frame.width ?? 0))x\(Int(live[id]?.container.frame.height ?? 0)) webHost=\(Int(webHost.frame.width))x\(Int(webHost.frame.height))"
        return out
    }

    /// Debug aid: builds the right-click menu for several situations and lists the items.
    public func debugContextMenus() async -> String {
        store.addTab(url: "http://127.0.0.1:8765/form.html", activate: true); showActive()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let tab = activeLive?.tab, let id = store.activeTabID else { return "no tab" }
        func titles(_ info: ContextMenuInfo) -> String { contextMenu(for: info, tab: tab, id: id).items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | ") }
        return "PAGE: " + titles(ContextMenuInfo()) + "\n\nLINK: " + titles(ContextMenuInfo(link: "https://example.com", linkText: "Example", hasLink: true))
            + "\n\nIMAGE: " + titles(ContextMenuInfo(mediaSource: "https://example.com/a.png", media: .image))
            + "\n\nTEXT: " + titles(ContextMenuInfo(selection: "hello world"))
            + "\n\nINPUT: " + titles(ContextMenuInfo(isEditable: true, misspelledWord: "helo", suggestions: ["hello", "help"]))
    }

    /// Debug aid: right-clicks inside the page with synthetic mouse events.
    public func debugRightClick() async {
        store.addTab(url: "http://127.0.0.1:8765/form.html", activate: true); showActive()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let tab = activeLive?.tab else { return }
        for type in ["mouseMoved", "mousePressed", "mouseReleased"] {
            var p: [String: Any] = ["type": type, "x": 100, "y": 60]
            if type != "mouseMoved" { p["button"] = "right"; p["clickCount"] = 1 }
            let data = try? JSONSerialization.data(withJSONObject: p)
            _ = try? await tab.devTools("Input.dispatchMouseEvent", params: data.flatMap { String(data: $0, encoding: .utf8) })
        }
    }

    /// Debug aid: a true picture of this window as the screen shows it (glass, web pages and all), taken with ScreenCaptureKit.
    public func debugRealSnapshot(to path: String) async -> String {
        guard let window else { return "no window" }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return "window not found among \(content.windows.count)" }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let config = SCStreamConfiguration()
            config.width = Int(target.frame.width * 2); config.height = Int(target.frame.height * 2)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            return "saved \(image.width)x\(image.height)"
        } catch { return "error: \(error.localizedDescription)" }
    }

    public func debugInternalPages() async -> String {
        var out = ""
        let custom = ProcessInfo.processInfo.environment["PANE_DEBUG_INTERNAL"].flatMap { $0.contains("://") ? $0.components(separatedBy: ",") : nil }
        for u in custom ?? ["chrome://version", "chrome://flags", "chrome://gpu", "chrome://history", "chrome://settings", "chrome://downloads", "chrome://net-internals", "chrome://chrome-urls", "chrome://about", "chrome://inspect", "chrome://webrtc-internals", "chrome://media-internals", "chrome://serviceworker-internals", "chrome://sandbox", "chrome://system", "chrome://histograms", "chrome://process-internals", "chrome://cache", "chrome://credits", "chrome://dino"] {
            store.addTab(url: u, activate: true); showActive()
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            let text = await activeLive?.tab.pageText() ?? ""
            out += "\(u): \(store.activeTabID.flatMap { store.tab($0)?.title } ?? "") | \(text.prefix(70).replacingOccurrences(of: "\n", with: " "))\n"
        }
        return out
    }

    public func debugSiteNotifications() async -> String {
        UserDefaults.standard.removeObject(forKey: "notificationDecisions")
        store.addTab(url: "http://127.0.0.1:8765/notif.html", activate: true); showActive()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard let tab = activeLive?.tab else { return "no tab" }
        let p = try? JSONSerialization.data(withJSONObject: ["expression": "JSON.stringify({r: window.result, shim: !!window.__paneNotif, kind: String(Notification).slice(0, 40), url: location.href})", "returnByValue": true])
        let r = (try? await tab.devTools("Runtime.evaluate", params: p.flatMap { String(data: $0, encoding: .utf8) })) ?? "none"
        return r + "\nposted: \(debugNotifications)\ndecisions: \(notificationDecisions)"
    }

    public func debugProbe() async -> String {
        store.addTab(url: "http://127.0.0.1:8765/probe.html", activate: true); showActive()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let tab = activeLive?.tab else { return "no tab" }
        var out = ""
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let params = try? JSONSerialization.data(withJSONObject: ["expression": "JSON.stringify(window.results)", "returnByValue": true])
            out = (try? await tab.devTools("Runtime.evaluate", params: params.flatMap { String(data: $0, encoding: .utf8) })) ?? "none"
            if out.contains("done") { break }
        }
        return out
    }

    public func debugPDF() async -> String {
        store.addTab(url: "http://127.0.0.1:8765/t.pdf", activate: true); showActive()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard let tab = activeLive?.tab else { return "no tab" }
        let js = "document.contentType + ' | embed=' + !!document.querySelector('embed') + ' | title=' + document.title + ' | url=' + location.href"
        let params = try? JSONSerialization.data(withJSONObject: ["expression": js, "returnByValue": true])
        let raw = try? await tab.devTools("Runtime.evaluate", params: params.flatMap { String(data: $0, encoding: .utf8) })
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let ov = store.activeTabID.flatMap { pdfOverlays[$0] }
        return (raw ?? "no result") + "\noverlay shown: \(ov != nil)"
    }

    public func debugPiP() async -> String {
        store.addTab(url: "http://127.0.0.1:8765/video.html", activate: true); showActive()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let tab = activeLive?.tab else { return "no tab" }
        let js = "(async () => { const v = document.querySelector('video'); try { await v.requestPictureInPicture(); return 'opened pip=' + !!document.pictureInPictureElement; } catch (e) { return 'error:' + e.name + ' ' + e.message; } })()"
        let params = try? JSONSerialization.data(withJSONObject: ["expression": js, "awaitPromise": true, "userGesture": true, "returnByValue": true])
        let raw = try? await tab.devTools("Runtime.evaluate", params: params.flatMap { String(data: $0, encoding: .utf8) })
        return raw ?? "no result"
    }

    public func debugLayoutInfo() -> String {
        guard let w = window, let c = w.contentView else { return "no window" }
        c.layoutSubtreeIfNeeded()
        func fit(_ v: NSView) -> String { "\(type(of: v)) fitting=\(Int(v.fittingSize.width))x\(Int(v.fittingSize.height)) intrinsic=\(v.intrinsicContentSize.width < 0 ? "none" : String(Int(v.intrinsicContentSize.width)))" }
        var lines = ["window frame=\(w.frame) contentMinSize=\(w.contentMinSize) contentMaxSize=\(w.contentMaxSize)", "content: \(fit(c))"]
        lines += webHost.subviews.map { "webHost child: \(fit($0))" }
        lines.append("startHost: \(fit(startHost))")
        lines.append("sidebar: \(fit(sidebar))")
        lines.append("assistant host width constraint=\(assistantWidth.constant)")
        lines.append("tabs: " + store.tabs.map { "\($0.id == agentPrivateTabID ? "[agent] " : "")\($0.url.isEmpty ? "(start page)" : $0.url)" }.joined(separator: " | "))
        func scan(_ v: NSView, _ depth: Int) {
            if v.fittingSize.width > 1500 || v.intrinsicContentSize.width > 1500 { lines.append(String(repeating: " ", count: depth) + "WIDE \(type(of: v)) fit=\(Int(v.fittingSize.width)) intrinsic=\(Int(v.intrinsicContentSize.width)) hidden=\(v.isHidden)") }
            v.subviews.forEach { scan($0, depth + 1) }
        }
        scan(c, 0)
        return lines.joined(separator: "\n")
    }

    public func debugHitTest() -> String {
        guard let content = window?.contentView else { return "no window" }
        let p = webHost.convert(NSPoint(x: webHost.bounds.midX, y: webHost.bounds.midY), to: content)
        var chain: [String] = []
        var v: NSView? = content.hitTest(content.convert(p, to: content.superview))
        while let cur = v { chain.append("\(type(of: cur))(hidden=\(cur.isHidden), alpha=\(cur.alphaValue))"); v = cur.superview }
        let subs = webHost.subviews.map { "\(type(of: $0)) hidden=\($0.isHidden) alpha=\($0.alphaValue) frame=\(Int($0.frame.width))x\(Int($0.frame.height))" }
        return "hit chain (leaf → root):\n  " + chain.joined(separator: "\n  ") + "\nwebHost subviews (back → front):\n  " + subs.joined(separator: "\n  ")
    }

    /// Debug aid: opens two pages and turns on split view, then reports where each page sits.
    public func debugSplit() async -> String {
        store.addTab(url: "http://127.0.0.1:8765/form.html", activate: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        store.addTab(url: "http://127.0.0.1:8765/ads.html", activate: false)
        toggleSplit(nil)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        webHost.layoutSubtreeIfNeeded()
        return "webHost \(webHost.frame)\n" + live.map { "\($0.key == store.activeTabID ? "ACTIVE" : ($0.key == splitID ? "SPLIT" : "other")) hidden=\($0.value.container.isHidden) frame=\($0.value.container.frame)" }.joined(separator: "\n")
    }

    /// Debug aid: types a login into a test page, submits it, and checks it was captured and can be filled back.
    public func debugPasswords() async -> String {
        let url = "http://127.0.0.1:8765/login.html"
        store.addTab(url: url, activate: true)
        showActive()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let tab = activeLive?.tab else { return "no tab" }
        func eval(_ e: String) async -> String { (try? await tab.devTools("Runtime.evaluate", params: Self.json(["expression": e, "returnByValue": true]))) ?? "error" }
        _ = await eval("document.getElementById('u').value='anna@example.com'; document.getElementById('p').value='s3cret pass'; document.querySelector('button').click(); 1")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var out = "saved: \(vault.logins.map { "\($0.host) \($0.user) pw=\(vault.password(for: $0) ?? "nil")" })\n"
        _ = await eval("document.getElementById('u').value=''; document.getElementById('p').value=''; 1")
        fillSavedLogin(nil)
        try? await Task.sleep(nanoseconds: 800_000_000)
        out += "after fill: " + (await eval("document.getElementById('u').value + '|' + document.getElementById('p').value")) + "\n"
        for l in vault.logins { vault.remove(l.id) }
        out += "after cleanup: \(vault.logins.count)"
        return out
    }

    public func debugPageText() async -> String { await activeLive?.tab.pageText() ?? "(no live page)" }

    public func debugAgentTranscript() -> String {
        "[panel open=\(assistantOpen) width=\(assistantWidth.constant) mode=\(assistantModel.mode) enabled=\(assistantModel.agentEnabled)]\n" + agent.items.map { item -> String in
            switch item {
            case .user(_, let t): return "USER: \(t)"
            case .assistant(_, let t): return "ASSISTANT: \(t)"
            case .step(let s): return "STEP [\(s.state)] \(s.title)\(s.note.map { " — \($0)" } ?? "")"
            case .notice(_, let t, let e): return "NOTICE\(e ? "(error)" : ""): \(t)"
            }
        }.joined(separator: "\n")
    }

    /// Debug aid: hides the sidebar (without saving that choice) and peeks it back in.
    public func debugPeek() {
        sidebarCollapsed = true
        columnLeading.constant = 0; sidebarWidth.constant = 0; barLeading.constant = 96
        resizeHandle.isHidden = true; edgeHover.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in MainActor.assumeIsolated { self?.setPeek(true) } }
    }

    /// Debug aid: the accessibility audit for one of this controller's windows.
    public func debugAudit(_ which: String) -> String {
        let w: NSWindow? = which == "settings" ? settingsWindow?.window : window
        return w.map { AccessibilityAudit.audit($0).text } ?? "(no window)"
    }

    /// Debug aid: types into the address bar so the suggestions dropdown can be photographed.
    public func debugShowSuggestions(query: String) {
        focusAddressBar()
        addressField.stringValue = query
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: addressField))
        suggestions.move(1)
    }

    @objc public func toggleShortcuts(_ sender: Any?) {
        if let o = shortcutsOverlay { o.dismiss(); shortcutsOverlay = nil; return }
        let o = ShortcutsOverlayView()
        o.onClose = { [weak self] in self?.shortcutsOverlay?.dismiss(); self?.shortcutsOverlay = nil }
        shortcutsOverlay = o
        o.present(in: rootView)
    }

    private func modelChanged() {
        sidebar.reload()
        scheduleSave()
    }

    private func bookmarksChanged() {
        syncScheduler?.scheduleSync()
        if !startHost.isHidden { refreshStartPage() }
        bookmarksBar.reload()
        bookmarksSidebar.reload()
        updateStar()
        bookmarksSaveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { guard let self, let s = self.storage else { return }; try? self.bookmarks.save(to: s.bookmarks) }
        }
        bookmarksSaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func scheduleHistorySave() {
        historySaveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { guard let self, let s = self.storage else { return }; try? self.history.save(to: s.history) }
        }
        historySaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    /// Workspaces of this profile (private windows have none).
    private lazy var workspaces = WorkspaceStore(directory: storage?.directory)
    private var sessionURL: URL? { storage == nil ? nil : workspaces.sessionURL(for: workspaces.activeID) }

    // MARK: Workspaces

    func switchWorkspace(_ id: UUID) {
        guard storage != nil, id != workspaces.activeID, workspaces.workspaces.contains(where: { $0.id == id }) else { return }
        // Keep what the old workspace had, then swap the whole tab set.
        saveWork?.cancel()
        if let u = sessionURL { try? store.save(to: u, excluding: agentPrivateTabID) }
        agent.stop()
        if findBar != nil { closeFind() }
        live.keys.forEach { destroyLive($0) }
        workspaces.activate(id)
        store.replaceSession(from: sessionURL, freshTabURL: settings.newTabURL)
        sidebar.refreshWorkspace()
        showActive()
        updateStar()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            webHost.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                webHost.animator().alphaValue = 1
            }
        }
        ToastView.show(in: webHost, message: String(localized: "Workspace: \(tr(workspaces.active.name))"), symbol: "square.stack.3d.up.fill", duration: 1.6)
    }

    /// Moves to the next (or previous) workspace, wrapping around.
    @objc public func nextWorkspace(_ s: Any?) { cycleWorkspace(1) }
    @objc public func previousWorkspace(_ s: Any?) { cycleWorkspace(-1) }
    private func cycleWorkspace(_ step: Int) {
        let list = workspaces.workspaces
        guard storage != nil, list.count > 1, let i = list.firstIndex(where: { $0.id == workspaces.activeID }) else { NSSound.beep(); return }
        switchWorkspace(list[(i + step + list.count) % list.count].id)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { guard let self, let s = self.storage else { return }; _ = s; if let u = self.sessionURL { try? self.store.save(to: u, excluding: self.agentPrivateTabID) } }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    // MARK: Traffic lights

    /// Grows the system titlebar to the toolbar height so the window buttons centre on the toolbar row.
    private func alignTrafficLights() {
        guard let window, let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        let h: CGFloat = 44
        let wanted = NSRect(x: 0, y: window.frame.height - h, width: window.frame.width, height: h)
        // AppKit re-lays the titlebar out on its own (resize, focus, hover, toolbar changes), so this runs on
        // every window update and only touches anything that has actually drifted.
        if container.frame != wanted { container.frame = wanted }
        if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
        // Inset the buttons so they sit inside the floating sidebar panel instead of on its corner.
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, t) in types.enumerated() {
            guard let b = window.standardWindowButton(t) else { continue }
            let x = 22 + CGFloat(i) * 20
            if abs(b.frame.origin.x - x) > 0.5 { b.setFrameOrigin(NSPoint(x: x, y: b.frame.origin.y)) }
        }
    }

    public func windowDidResize(_ notification: Notification) {
        if assistantOpen, abs(assistantWidth.constant - assistantTargetWidth) > 1 { assistantWidth.constant = assistantTargetWidth }
        scheduleWindowFixups()
    }

    private var fixupsScheduled = false
    /// Moving the titlebar or the window from inside a layout pass makes AppKit re-lay the window out again and again
    /// (and eventually throw), so these adjustments wait for the next turn of the run loop.
    private func scheduleWindowFixups() {
        guard !fixupsScheduled else { return }
        fixupsScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fixupsScheduled = false
                self.alignTrafficLights()
                self.keepWindowOnScreen()
            }
        }
    }

    private var clamping = false
    /// A saved or dragged frame can end up far wider than any screen, or entirely off the displays (after unplugging a
    /// monitor, say). Whatever the cause, the window is brought back to something usable.
    func keepWindowOnScreen() {
        guard let w = window, !clamping, !w.styleMask.contains(.fullScreen), !w.isZoomed else { return }
        let screens = NSScreen.screens
        guard let screen = w.screen ?? NSScreen.main ?? screens.first else { return }
        // Constraints can never stretch the window past the biggest display.
        w.maxSize = NSSize(width: screens.map { $0.frame.width }.max() ?? 4000, height: screens.map { $0.frame.height }.max() ?? 3000)
        let vis = screen.visibleFrame
        var f = w.frame
        let lost = !screens.contains { $0.visibleFrame.intersection(f).width >= 120 && $0.visibleFrame.intersection(f).height >= 80 }
        if f.width > vis.width + 1 || f.height > vis.height + 1 || lost {
            f.size.width = min(f.width, vis.width)
            f.size.height = min(f.height, vis.height)
            if lost || f.maxX > vis.maxX || f.minX < vis.minX {
                f.origin.x = vis.midX - f.width / 2
                f.origin.y = vis.midY - f.height / 2
            }
            clamping = true
            w.setFrame(f, display: true)
            clamping = false
        }
    }
    public func windowDidUpdate(_ notification: Notification) { scheduleWindowFixups() }
    public func windowDidBecomeKey(_ notification: Notification) { scheduleWindowFixups() }
    public func windowDidResignKey(_ notification: Notification) { scheduleWindowFixups() }
    public func windowWillEnterFullScreen(_ notification: Notification) { isFullScreen = true; updateBarLeading() }
    public func windowDidExitFullScreen(_ notification: Notification) { isFullScreen = false; updateBarLeading(); scheduleWindowFixups() }

    private func updateBarLeading() {
        let wanted: CGFloat = (sidebarCollapsed && !isFullScreen) ? 96 : 4
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            barLeading.animator().constant = wanted
        }
    }

    /// Writes everything to disk right now (quit, window close) instead of waiting for the debounce timers.
    public func saveNow() {
        saveWork?.cancel(); bookmarksSaveWork?.cancel(); historySaveWork?.cancel(); downloadsSaveWork?.cancel()
        guard let s = storage else { return }  // a private window leaves nothing behind
        try? downloads.save(to: s.downloads)
        _ = s
        if let u = sessionURL { try? store.save(to: u, excluding: agentPrivateTabID) }
        try? bookmarks.save(to: s.bookmarks)
        try? history.save(to: s.history)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        let env = ProcessInfo.processInfo.environment
        return env["PANE_DEBUG_STRESS_ALL"] == nil && env["PANE_DEBUG_SIDEBAR"] == nil
    }

    public func windowWillClose(_ notification: Notification) {
        saveNow()
        live.keys.forEach { destroyLive($0) }  // closes the web views, which ends a private window's session
        onClosed?()
    }

    // MARK: Layout

    private func buildInterface(in window: NSWindow) {
        let root = NSView()
        rootView = root

        sidebar = TabSidebarView(store: store)
        sidebar.commands = self
        if storage != nil {
            sidebar.workspaces = workspaces
            sidebar.onSwitchWorkspace = { [weak self] id in self?.switchWorkspace(id) }
        }
        sidebar.favicon = { [weak self] id in
            guard let self else { return nil }
            return self.favicons[id] ?? self.store.tab(id).flatMap { self.faviconCache.image(for: $0.url) }
        }
        sidebar.isLoading = { [weak self] id in self?.navState[id]?.isLoading ?? false }
        sidebar.isAudible = { [weak self] id in self?.audible.contains(id) ?? false }
        sidebar.isMuted = { [weak self] id in self?.muted.contains(id) ?? false }
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        bookmarksSidebar = BookmarksSidebarView(store: bookmarks)
        bookmarksSidebar.icon = { [weak self] url in self?.faviconCache.image(for: url) }
        bookmarksSidebar.onOpen = { [weak self] n, newTab in self?.openBookmark(n, newTab: newTab) }
        bookmarksSidebar.onDropTab = { [weak self] tab, folder, before in self?.bookmarkTab(tab, in: folder, before: before) }
        bookmarksSidebar.importMenu = { [weak self] in self?.makeImportMenu() ?? NSMenu() }
        bookmarksSidebar.translatesAutoresizingMaskIntoConstraints = false
        bookmarksSidebar.isHidden = true

        modeControl = NSSegmentedControl(images: [
            NSImage(systemSymbolName: "square.stack", accessibilityDescription: tr("Tabs")) ?? NSImage(),
            NSImage(systemSymbolName: "star", accessibilityDescription: tr("All Bookmarks")) ?? NSImage(),
        ], trackingMode: .selectOne, target: self, action: #selector(sidebarModeChanged(_:)))
        modeControl.selectedSegment = 0
        modeControl.segmentStyle = .automatic
        modeControl.setToolTip(tr("Tabs"), forSegment: 0)
        modeControl.setToolTip(ShortcutCatalog.hint("All Bookmarks", "Show All Bookmarks"), forSegment: 1)
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        updateButton = NSButton(title: "", target: self, action: #selector(updateClicked))
        updateButton.bezelStyle = { if #available(macOS 26.0, *) { return .glass }; return .texturedRounded }()
        updateButton.imagePosition = .imageLeading
        updateButton.imageHugsTitle = true
        updateButton.font = .systemFont(ofSize: 13, weight: .semibold)
        updateButton.bezelColor = .controlAccentColor
        updateButton.contentTintColor = .white
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        updateButton.isHidden = true
        let updateSlot = NSView()
        updateSlot.translatesAutoresizingMaskIntoConstraints = false
        updateSlot.addSubview(updateButton)
        updateSlot.wantsLayer = true
        updateSlot.layer?.masksToBounds = true
        updateSlotHeight = updateSlot.heightAnchor.constraint(equalToConstant: 0)

        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(sidebar); pane.addSubview(bookmarksSidebar); pane.addSubview(updateSlot); pane.addSubview(modeControl)
        NSLayoutConstraint.activate([
            updateSlot.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            updateSlot.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
            updateSlot.bottomAnchor.constraint(equalTo: modeControl.topAnchor, constant: -4),
            updateSlotHeight,
            updateButton.leadingAnchor.constraint(equalTo: updateSlot.leadingAnchor),
            updateButton.trailingAnchor.constraint(equalTo: updateSlot.trailingAnchor),
            updateButton.centerYAnchor.constraint(equalTo: updateSlot.centerYAnchor),
            updateButton.heightAnchor.constraint(equalToConstant: 32),
            modeControl.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            modeControl.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
            modeControl.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -12),
        ])
        for v in [sidebar!, bookmarksSidebar!] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: pane.leadingAnchor), v.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
                v.topAnchor.constraint(equalTo: pane.topAnchor), v.bottomAnchor.constraint(equalTo: updateSlot.topAnchor, constant: -2),
            ])
        }
        switch kind {
        case .standard: break
        case .privateSession:
            let badge = ProfileBadge(text: "Private", symbol: "lock.shield.fill", color: .systemPurple)
            badge.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(badge)
            NSLayoutConstraint.activate([badge.topAnchor.constraint(equalTo: pane.topAnchor, constant: 15), badge.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -14)])
        case .profile(let p):
            let badge = ProfileBadge(text: p.name, symbol: "person.crop.circle.fill", color: GroupPalette.color(p.colorIndex))
            badge.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(badge)
            NSLayoutConstraint.activate([badge.topAnchor.constraint(equalTo: pane.topAnchor, constant: 15), badge.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -14)])
        }
        let sidebarBox = HoverBox()
        sidebarBox.wantsLayer = true
        sidebarBox.layer?.masksToBounds = true
        sidebarBox.translatesAutoresizingMaskIntoConstraints = false
        // The sidebar floats as its own rounded glass panel.
        let sidebarGlass = Glass.surface(content: pane, cornerRadius: 22)
        sidebarSurface = sidebarGlass
        sidebarBox.addSubview(sidebarGlass)

        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false

        let toggle = Glass.button(symbol: "sidebar.left", label: "Toggle Sidebar", target: self, action: #selector(toggleSidebar))
        back = Glass.button(symbol: "chevron.left", label: "Back", target: self, action: #selector(goBack))
        forward = Glass.button(symbol: "chevron.right", label: "Forward", target: self, action: #selector(goForward))
        reloadButton = Glass.button(symbol: "arrow.clockwise", label: "Reload", target: self, action: #selector(reload))
        toggle.toolTip = ShortcutCatalog.hint("Toggle Sidebar", "Toggle Sidebar")
        back.toolTip = ShortcutCatalog.hint("Back", "Back")
        forward.toolTip = ShortcutCatalog.hint("Forward", "Forward")
        reloadButton.toolTip = ShortcutCatalog.hint("Reload", "Reload")
        downloadsButton = Glass.button(symbol: "arrow.down.circle", label: "Downloads", target: self, action: #selector(toggleDownloads(_:)))
        downloadsButton.toolTip = ShortcutCatalog.hint("Downloads", "Show Downloads")
        downloadsButton.isHidden = true
        assistantButton = Glass.button(symbol: "sparkles", label: "Ask the Assistant", target: self, action: #selector(toggleAssistant(_:)))
        assistantButton.toolTip = ShortcutCatalog.hint("Ask the Assistant", "Ask the Assistant")
        back.isEnabled = false
        forward.isEnabled = false

        addressField.placeholderString = tr("Search or enter address")
        addressField.isBordered = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        addressField.font = .systemFont(ofSize: 13)
        addressField.alignment = .center
        addressField.onFocusChange = { [weak self] focused in self?.addressFocusChanged(focused) }
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.usesSingleLineMode = true
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(commitAddress)
        addressField.setAccessibilityLabel(tr("Address"))
        addressField.cell?.setAccessibilityLabel(tr("Address"))
        addressField.translatesAutoresizingMaskIntoConstraints = false
        let fieldBox = NSView()
        starButton = NSButton(image: NSImage(systemSymbolName: "star", accessibilityDescription: tr("Bookmark This Page")) ?? NSImage(),
                              target: self, action: #selector(bookmarkThisPage(_:)))
        starButton.isBordered = false
        starButton.imageScaling = .scaleProportionallyDown
        starButton.toolTip = ShortcutCatalog.hint("Bookmark This Page", "Bookmark This Page")
        starButton.setAccessibilityLabel(tr("Bookmark This Page"))
        starButton.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: tr("Secure connection"))
        lockIcon.contentTintColor = .tertiaryLabelColor
        lockIcon.imageScaling = .scaleProportionallyDown
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.isHidden = true
        lockIcon.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showSiteInfo(_:))))
        fieldBox.addSubview(addressField)
        fieldBox.addSubview(starButton)
        fieldBox.addSubview(lockIcon)
        loadingBar.translatesAutoresizingMaskIntoConstraints = false
        fieldBox.addSubview(loadingBar)
        let pill = Glass.surface(content: fieldBox, cornerRadius: 14, interactive: true)
        NSLayoutConstraint.activate([
            loadingBar.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 16),
            loadingBar.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -16),
            loadingBar.bottomAnchor.constraint(equalTo: fieldBox.bottomAnchor, constant: -2),
            loadingBar.heightAnchor.constraint(equalToConstant: 2),
            lockIcon.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 12),
            lockIcon.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 12), lockIcon.heightAnchor.constraint(equalToConstant: 12),
            addressField.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 34),
            addressField.trailingAnchor.constraint(equalTo: starButton.leadingAnchor, constant: -6),
            addressField.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
            starButton.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -10),
            starButton.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
            starButton.widthAnchor.constraint(equalToConstant: 18), starButton.heightAnchor.constraint(equalToConstant: 18),
        ])
        addressPill = pill
        pill.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        addressField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        // However long the address is, the field must never ask the window to grow.
        addressField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        // The page stays opaque; glass wraps around it.
        webHost.translatesAutoresizingMaskIntoConstraints = false

        // Each icon button sits on its own interactive glass; the container below lets neighbours merge like system toolbars.
        func hosted(_ b: NSButton) -> NSView { (b as? ToolbarButton)?.host ?? b }
        let bar = NSStackView(views: [hosted(toggle), hosted(back), hosted(forward), hosted(reloadButton), pill, hosted(downloadsButton), hosted(assistantButton)])
        bar.spacing = 6
        bar.distribution = .fill
        bar.translatesAutoresizingMaskIntoConstraints = false
        startHost = StartPageHostingView(rootView: StartPageView(model: startModel))
        startHost.translatesAutoresizingMaskIntoConstraints = false
        startHost.isHidden = true
        webHost.addSubview(startHost)
        NSLayoutConstraint.activate([
            startHost.leadingAnchor.constraint(equalTo: webHost.leadingAnchor), startHost.trailingAnchor.constraint(equalTo: webHost.trailingAnchor),
            startHost.topAnchor.constraint(equalTo: webHost.topAnchor), startHost.bottomAnchor.constraint(equalTo: webHost.bottomAnchor),
        ])
        startModel.onSearch = { [weak self] q in
            guard let self, let url = AddressInput.resolve(q, engine: self.settings.searchEngine) else { return }
            self.navigate(url)
        }
        startModel.onOpen = { [weak self] url, newTab in self?.open(url, newTab: newTab) }
        statusBubble.attach(to: webHost)
        agentOverlay = AgentOverlayView()
        agentOverlay.translatesAutoresizingMaskIntoConstraints = false
        webHost.addSubview(agentOverlay)
        NSLayoutConstraint.activate([
            agentOverlay.leadingAnchor.constraint(equalTo: webHost.leadingAnchor), agentOverlay.trailingAnchor.constraint(equalTo: webHost.trailingAnchor),
            agentOverlay.topAnchor.constraint(equalTo: webHost.topAnchor), agentOverlay.bottomAnchor.constraint(equalTo: webHost.bottomAnchor),
        ])
        agentPill = AgentStatusPill()
        agentPill.onStop = { [weak self] in self?.agent.stop() }
        agentPill.attach(to: webHost)
        bookmarksBar = BookmarksBarView(store: bookmarks)
        bookmarksBar.icon = { [weak self] url in self?.faviconCache.image(for: url) }
        bookmarksBar.onOpen = { [weak self] n, newTab in self?.openBookmark(n, newTab: newTab) }
        bookmarksBar.onDropTab = { [weak self] tab, before in self?.bookmarkTab(tab, in: nil, before: before) }
        bookmarksBar.menuProvider = { [weak self] n in self?.bookmarkMenu(for: n) }
        bookmarksBar.translatesAutoresizingMaskIntoConstraints = false
        barGlass = Glass.surface(content: bookmarksBar, cornerRadius: 12)
        let barBox: NSView
        if #available(macOS 26.0, *) {
            let c = NSGlassEffectContainerView()
            c.spacing = 8
            c.contentView = bar
            barBox = c
        } else {
            barBox = bar
        }
        barBox.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(barBox)
        column.addSubview(barGlass)
        column.addSubview(webHost)
        column.addSubview(suggestions)
        suggestions.translatesAutoresizingMaskIntoConstraints = false
        suggestions.icon = { [weak self] url in self?.faviconCache.image(for: url) }
        suggestions.engineName = { [weak self] in self?.settings.searchEngine.name ?? tr("the web") }
        suggestions.onChoose = { [weak self] row in self?.chooseSuggestion(row) }
        NSLayoutConstraint.activate([
            suggestions.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            suggestions.widthAnchor.constraint(equalTo: pill.widthAnchor),
            suggestions.topAnchor.constraint(equalTo: barBox.bottomAnchor, constant: 6),
        ])

        assistantResizeHandle = SidebarResizeHandle()
        assistantResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        assistantResizeHandle.isHidden = true
        assistantResizeHandle.onDrag = { [weak self] dx in self?.resizeAssistant(by: dx) }
        resizeHandle = SidebarResizeHandle()
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.onDrag = { [weak self] dx in self?.resizeSidebar(by: dx) }

        // Assistant panel: a floating glass card on the right that pushes the page over when it opens.
        assistantModel = AssistantPanelModel(session: assistantSession, agent: agent)
        assistantModel.macros = MacroStore(directory: storage?.directory)
        assistantModel.history = AgentHistoryStore(directory: storage?.directory)
        assistantModel.onRestore = { [weak self] run in self?.agent.restore(run) }
        agent.onRunFinished = { [weak self] run in self?.assistantModel.history.upsert(run) }
        assistantModel.autoApprove = !settings.agentConfirm
        assistantModel.onAutoApproveChanged = { [weak self] on in self?.settings.agentConfirm = !on }
        assistantModel.agentPrivate = settings.agentPrivate
        assistantModel.onAgentPrivateChanged = { [weak self] on in self?.settings.agentPrivate = on }
        assistantModel.onSaveMacro = { [weak self] prompt in self?.saveMacro(prompt) }
        assistantModel.onToggleFloating = { [weak self] in guard let self else { return }; self.setAssistantFloating(!self.assistantFloating) }
        assistantModel.onSend = { [weak self] q in
            guard let self else { return }
            if self.assistantModel.mode == .act { self.agent.send(q) } else { self.askAssistant(q) }
        }
        assistantModel.onOpenSettings = { [weak self] in self?.showSettings(nil) }
        assistantModel.onClose = { [weak self] in self?.toggleAssistant(nil) }
        let assistantHost = NSHostingView(rootView: AssistantPanelView(model: assistantModel, session: assistantSession, agent: agent))
        assistantHost.sizingOptions = []  // our constraints decide its size, not the SwiftUI content
        assistantHost.translatesAutoresizingMaskIntoConstraints = false
        let assistantCard = Glass.surface(content: assistantHost, cornerRadius: 22)
        let assistantBox = NSView()
        assistantBox.wantsLayer = true
        assistantBox.layer?.masksToBounds = true
        assistantBox.translatesAutoresizingMaskIntoConstraints = false
        assistantBox.addSubview(assistantCard)
        assistantWidth = assistantBox.widthAnchor.constraint(equalToConstant: 0)

        edgeHover = HoverBox()
        edgeHover.translatesAutoresizingMaskIntoConstraints = false
        edgeHover.isHidden = !sidebarCollapsed
        root.addSubview(column); root.addSubview(sidebarBox); root.addSubview(assistantBox); root.addSubview(resizeHandle); root.addSubview(assistantResizeHandle); root.addSubview(edgeHover)
        NSLayoutConstraint.activate([
            edgeHover.leadingAnchor.constraint(equalTo: root.leadingAnchor), edgeHover.widthAnchor.constraint(equalToConstant: 6),
            edgeHover.topAnchor.constraint(equalTo: root.topAnchor, constant: 44), edgeHover.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        edgeHover.onEnter = { [weak self] in self?.schedulePeek(true) }
        edgeHover.onExit = { [weak self] in self?.peekWork?.cancel() }
        sidebarBox.onEnter = { [weak self] in self?.peekWork?.cancel() }
        sidebarBox.onExit = { [weak self] in self?.schedulePeek(false) }
        NSLayoutConstraint.activate([
            assistantBox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            assistantBox.topAnchor.constraint(equalTo: root.topAnchor), assistantBox.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            assistantWidth,
            assistantCard.trailingAnchor.constraint(equalTo: assistantBox.trailingAnchor, constant: -8),
            assistantCard.topAnchor.constraint(equalTo: assistantBox.topAnchor, constant: 8),
            assistantCard.bottomAnchor.constraint(equalTo: assistantBox.bottomAnchor, constant: -8),
            assistantCard.leadingAnchor.constraint(equalTo: assistantBox.leadingAnchor, constant: 2),  // the card takes whatever width the panel has
        ])

        sidebarWidth = sidebarBox.widthAnchor.constraint(equalToConstant: sidebarCollapsed ? 0 : expandedWidth)
        // The page's left edge is its own constraint (not glued to the sidebar) so the sidebar can float over it.
        columnLeading = column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: sidebarCollapsed ? 0 : expandedWidth)
        sidebarContentWidth = sidebarGlass.widthAnchor.constraint(equalToConstant: expandedWidth - 8)
        barLeading = barBox.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: sidebarCollapsed ? 96 : 4)
        NSLayoutConstraint.activate([
            sidebarBox.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarBox.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarBox.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth, sidebarContentWidth,
            sidebarGlass.leadingAnchor.constraint(equalTo: sidebarBox.leadingAnchor, constant: 8),
            sidebarGlass.topAnchor.constraint(equalTo: sidebarBox.topAnchor, constant: 8),
            sidebarGlass.bottomAnchor.constraint(equalTo: sidebarBox.bottomAnchor, constant: -8),

            assistantResizeHandle.centerXAnchor.constraint(equalTo: assistantBox.leadingAnchor, constant: 3),
            assistantResizeHandle.widthAnchor.constraint(equalToConstant: 8),
            assistantResizeHandle.topAnchor.constraint(equalTo: root.topAnchor),
            assistantResizeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            resizeHandle.centerXAnchor.constraint(equalTo: sidebarBox.trailingAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),
            resizeHandle.topAnchor.constraint(equalTo: root.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            columnLeading,
            column.trailingAnchor.constraint(equalTo: assistantBox.leadingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            barLeading,
            barBox.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -12),
            barBox.topAnchor.constraint(equalTo: column.topAnchor, constant: 8),
            barBox.heightAnchor.constraint(equalToConstant: 30),
            pill.heightAnchor.constraint(equalToConstant: 28),
            webHost.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 6),
            webHost.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -8),
            webHost.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -8),
        ])
        barHeight = barGlass.heightAnchor.constraint(equalToConstant: bookmarksBarVisible ? 24 : 0)
        barTop = barGlass.topAnchor.constraint(equalTo: barBox.bottomAnchor, constant: bookmarksBarVisible ? 6 : 0)
        webTop = webHost.topAnchor.constraint(equalTo: barGlass.bottomAnchor, constant: bookmarksBarVisible ? 6 : 8)
        NSLayoutConstraint.activate([
            barHeight, barTop, webTop,
            barGlass.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 6),
            barGlass.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -8),
        ])
        barGlass.isHidden = !bookmarksBarVisible
        resizeHandle.isHidden = sidebarCollapsed

        let glass = Glass.surface(content: root, tint: isPrivate ? NSColor.systemPurple.withAlphaComponent(0.22) : nil)
        glass.translatesAutoresizingMaskIntoConstraints = true
        windowGlass = glass
        window.contentView = glass
    }

    // MARK: Address display

    /// Idle: just the site (like Safari). Focused: the full, editable URL.
    private func displayString(for url: String) -> String {
        guard let u = URL(string: url), let host = u.host, u.scheme == "https" || u.scheme == "http" else { return url == "about:blank" ? "" : url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func setAddress(_ url: String) {
        addressFull = url
        lockIcon.isHidden = !url.hasPrefix("https://")
        if !isEditingAddress { addressField.stringValue = displayString(for: url) }
    }

    private func addressFocusChanged(_ focused: Bool) {
        isEditingAddress = focused
        if !focused { suggestions.hide() }
        addressField.alignment = focused ? .left : .center
        if focused {
            addressField.stringValue = addressFull
            DispatchQueue.main.async { [weak self] in self?.addressField.currentEditor()?.selectAll(nil) }
        } else {
            addressField.stringValue = displayString(for: addressFull)
        }
        if #available(macOS 26.0, *), let glass = addressPill as? NSGlassEffectView {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                glass.animator().tintColor = focused ? NSColor.controlAccentColor.withAlphaComponent(0.22) : nil
            }
        }
    }

    // MARK: Sidebar

    /// Hovering the left edge of a window whose sidebar is hidden slides it in over the page; leaving hides it again.
    private func schedulePeek(_ show: Bool) {
        peekWork?.cancel()
        guard sidebarCollapsed, peeking != show else { return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.setPeek(show) } }
        peekWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (show ? 0.15 : 0.45), execute: w)
    }

    private func setPeek(_ show: Bool) {
        guard sidebarCollapsed, peeking != show else { return }
        peeking = show
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.01 : 0.28
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            sidebarWidth.animator().constant = show ? expandedWidth : 0  // the page stays where it is
        }
        edgeHover.isHidden = show
    }

    @objc public func toggleSidebar() {
        sidebarCollapsed.toggle()
        peeking = false
        peekWork?.cancel()
        edgeHover.isHidden = !sidebarCollapsed
        UserDefaults.standard.set(sidebarCollapsed, forKey: Defaults.collapsed)
        resizeHandle.isHidden = sidebarCollapsed
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            sidebarWidth.animator().constant = sidebarCollapsed ? 0 : expandedWidth
            columnLeading.animator().constant = sidebarCollapsed ? 0 : expandedWidth
            barLeading.animator().constant = (sidebarCollapsed && !isFullScreen) ? 96 : 4
        }
    }

    private func resizeSidebar(by dx: CGFloat) {
        guard !sidebarCollapsed else { return }
        expandedWidth = min(max(expandedWidth + dx, 190), 380)
        sidebarWidth.constant = expandedWidth
        columnLeading.constant = expandedWidth
        sidebarContentWidth.constant = expandedWidth - 8
        UserDefaults.standard.set(Double(expandedWidth), forKey: Defaults.width)
    }

    // MARK: Updates

    @objc private func updateClicked() {
        guard let updater else { return }
        if case .failed = updater.state { updater.checkNow(userInitiated: true) } else { updater.install() }
    }

    @objc public func checkForUpdates(_ sender: Any?) {
        guard let updater else { return }
        userCheckPending = true
        updater.checkNow(userInitiated: true)
    }

    private func updateStateChanged(_ state: UpdateState) {
        updateStatus.state = state
        var title = "", symbol = "arrow.down.circle.fill", visible = true, enabled = true, tip = ""
        switch state {
        case .idle, .checking:
            visible = false
        case .available(let info):
            title = String(localized: "Update (\(info.build))")
            tip = info.notes.isEmpty ? tr("A new version of Pane is ready.") : info.notes
        case .downloading(let p):
            title = p >= 0 ? String(localized: "Downloading… \(Int(p * 100))%") : tr("Downloading…")
            enabled = false
        case .installing:
            title = tr("Restarting…"); symbol = "arrow.triangle.2.circlepath"; enabled = false
        case .failed(let message):
            title = tr("Update failed — Retry"); symbol = "exclamationmark.triangle.fill"; tip = message
        }
        updateButton.isHidden = !visible
        updateButton.title = title
        updateButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        updateButton.isEnabled = enabled
        updateButton.toolTip = tip
        updateButton.setAccessibilityLabel(title)
        let target: CGFloat = visible ? 38 : 0
        if updateSlotHeight.constant != target {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                ctx.allowsImplicitAnimation = true
                updateSlotHeight.animator().constant = target
            }
        }
        if userCheckPending {
            switch state {
            case .idle:
                userCheckPending = false
                showAlert("Pane is up to date", "You have the latest version.")
            case .failed(let m):
                userCheckPending = false
                showAlert("Couldn't check for updates", m)
            case .available: userCheckPending = false
            default: break
            }
        }
    }

    // MARK: Assistant (⇧⌘A)

    @objc public func stopAgent(_ sender: Any?) { agent.stop() }

    /// The panel takes a third of a wide window and never less than 320 pt, so it stays readable on small windows
    /// without squeezing the page on big ones.
    private var assistantTargetWidth: CGFloat {
        let windowWidth = window?.frame.width ?? 1280
        if let preferred = UserDefaults.standard.object(forKey: "assistantWidth") as? Double {
            return min(max(CGFloat(preferred), 300), max(300, min(640, windowWidth * 0.6)))   // the width you dragged it to
        }
        return min(max(windowWidth * 0.30, 330), 460)
    }

    /// Dragging the panel's left edge changes its width (remembered).
    private func resizeAssistant(by dx: CGFloat) {
        guard assistantOpen else { return }
        let width = min(max(assistantWidth.constant - dx, 300), max(300, min(640, (window?.frame.width ?? 1280) * 0.6)))
        assistantWidth.constant = width
        UserDefaults.standard.set(Double(width), forKey: "assistantWidth")
    }

    // MARK: Floating assistant window

    private var floatingAssistant: NSPanel?
    private var assistantFloating = false

    /// Moves the assistant between the side of the window and a window of its own that stays above the browser.
    func setAssistantFloating(_ on: Bool) {
        guard on != assistantFloating else { return }
        assistantFloating = on
        assistantModel.isFloating = on
        if on {
            if assistantOpen { assistantOpen = false; assistantWidth.constant = 0; assistantButton.contentTintColor = nil }
            showFloatingAssistant()
        } else {
            floatingAssistant?.orderOut(nil)
            if !assistantOpen { toggleAssistant(nil) }
        }
        assistantButton.contentTintColor = (assistantOpen || (assistantFloating && floatingAssistant?.isVisible == true)) ? .controlAccentColor : nil
    }

    private func showFloatingAssistant() {
        if floatingAssistant == nil {
            let host = NSHostingView(rootView: AssistantPanelView(model: assistantModel, session: assistantSession, agent: agent))
            host.sizingOptions = []
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 640), styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.minSize = NSSize(width: 300, height: 360)
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true; panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = Glass.surface(content: host, cornerRadius: 0)
            panel.setFrameAutosaveName("PaneFloatingAssistant")
            if !panel.setFrameUsingName("PaneFloatingAssistant"), let w = window {
                let f = w.frame; panel.setFrameOrigin(NSPoint(x: f.maxX - 420, y: f.minY + 60))
            }
            panel.delegate = floatingDelegate
            floatingAssistant = panel
        }
        refreshAssistantModel()
        floatingAssistant?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in MainActor.assumeIsolated { self?.assistantModel.focusToken += 1 } }
    }

    private lazy var floatingDelegate = FloatingDelegate { [weak self] in
        guard let self, self.assistantFloating else { return }
        self.assistantFloating = false; self.assistantModel.isFloating = false
        self.assistantButton.contentTintColor = nil
    }

    private final class FloatingDelegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { MainActor.assumeIsolated { onClose() } }
    }

    /// View ▸ Floating Assistant Window.
    @objc public func toggleFloatingAssistant(_ sender: Any?) { setAssistantFloating(!assistantFloating) }

    @objc public func toggleAssistant(_ sender: Any?) {
        if assistantFloating {
            if let p = floatingAssistant, p.isVisible { p.orderOut(nil); assistantButton.contentTintColor = nil } else { showFloatingAssistant(); assistantButton.contentTintColor = .controlAccentColor }
            return
        }
        assistantOpen.toggle()
        assistantResizeHandle.isHidden = !assistantOpen
        if assistantOpen { refreshAssistantModel() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.01 : 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            ctx.allowsImplicitAnimation = true
            assistantWidth.animator().constant = assistantOpen ? assistantTargetWidth : 0
        }
        assistantButton.contentTintColor = assistantOpen ? .controlAccentColor : nil
        if assistantOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in MainActor.assumeIsolated { self?.assistantModel.focusToken += 1 } }
        } else if let c = store.activeTabID.flatMap({ live[$0]?.container }) {
            window?.makeFirstResponder(c.subviews.first)
        }
    }

    /// Debug aid: opens the panel and asks a question right away.
    public func debugAssistant(question: String?) {
        toggleAssistant(nil)
        if assistantOpen { assistantWidth.constant = assistantTargetWidth }  // snapshot runs don't always run the animation
        if let q = question { askAssistant(q) }
    }

    private func refreshAssistantModel() {
        guard assistantModel != nil else { return }
        assistantModel.configured = assistantSession.isConfigured
        assistantModel.agentEnabled = settings.agentEnabled || debugForceAct
        if !settings.agentEnabled && !debugForceAct { assistantModel.mode = .ask }
        agent.confirmImportantActions = settings.agentConfirm
        let active = store.activeTabID.flatMap { store.tab($0) }
        assistantModel.currentTitle = active?.displayTitle ?? ""
        assistantModel.canShareCurrent = active.map { live[$0.id] != nil } ?? false
        assistantModel.available = live.keys.filter { $0 != active?.id }.compactMap { id in
            store.tab(id).map { AssistantPanelModel.TabChoice(id: id, title: $0.displayTitle) }
        }.sorted { $0.title < $1.title }
        assistantModel.extraTabs = assistantModel.extraTabs.filter { live[$0.id] != nil }
    }

    /// Reads the pages the user chose to share, then asks. Only live pages can be read; sleeping tabs are skipped.
    private func askAssistant(_ question: String) {
        guard !gatheringForAssistant else { return }
        gatheringForAssistant = true
        Task {
            var contexts: [PageContext] = []
            if assistantModel.includeCurrent, let id = store.activeTabID, let l = live[id], let t = store.tab(id) {
                contexts.append(PageContext(title: t.displayTitle, url: t.url, text: await l.tab.pageText()))
            }
            for choice in assistantModel.extraTabs {
                guard let l = live[choice.id], let t = store.tab(choice.id), !contexts.contains(where: { $0.url == t.url }) else { continue }
                contexts.append(PageContext(title: t.displayTitle, url: t.url, text: await l.tab.pageText()))
            }
            gatheringForAssistant = false
            assistantSession.send(question, contexts: contexts)
        }
    }

    private func testAssistantConnection() async -> (ok: Bool, text: String) {
        guard let provider = assistantSession.makeProvider() else { return (false, tr("Add an API key first.")) }
        do {
            var got = ""
            for try await chunk in provider.stream(system: "Reply with one short word.", messages: [LLMMessage(role: "user", content: "Say OK")]) {
                got += chunk
                if got.count > 1 { break }
            }
            return (true, got.isEmpty ? tr("Connected.") : tr("Connected — the model answered."))
        } catch {
            return (false, (error as? AssistantError)?.message ?? error.localizedDescription)
        }
    }

    // MARK: Downloads

    private func downloadsChanged() {
        updateDownloadsButton()
        downloadsSaveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { guard let self, let s = self.storage else { return }; try? self.downloads.save(to: s.downloads) }
        }
        downloadsSaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func updateDownloadsButton() {
        let hadItems = !downloadsButton.isHidden
        let doneCount = downloads.items.filter { $0.state == .complete }.count
        if doneCount > lastDoneDownloads { pulse(downloadsButton, symbol: "checkmark.circle.fill", tint: .systemGreen) }
        lastDoneDownloads = doneCount
        downloadsButton.isHidden = downloads.items.isEmpty
        let active = downloads.hasActive
        downloadsButton.image = NSImage(systemSymbolName: active ? "arrow.down.circle.fill" : "arrow.down.circle",
                                        accessibilityDescription: tr("Downloads"))
        downloadsButton.contentTintColor = active ? .controlAccentColor : nil
        if !hadItems && !downloadsButton.isHidden, let host = (downloadsButton as? ToolbarButton)?.host { host.alphaValue = 0; host.animator().alphaValue = 1 }
    }

    // MARK: Page notes

    public lazy var notes = NoteStore(directory: kind.isPrivate ? nil : storage?.directory)
    private var notePopover: NSPopover?

    /// Opens the note card for the current page (⌥⌘N).
    @objc public func addNote(_ s: Any?) {
        guard notes.isPersistent, let id = store.activeTabID, let t = store.tab(id), t.url.hasPrefix("http") else { NSSound.beep(); return }
        if let p = notePopover, p.isShown { p.performClose(nil); return }
        let host = URL(string: t.url)?.host ?? t.url
        let pop = NSPopover()
        pop.behavior = .transient
        let host_ = NSHostingController(rootView: NoteEditorView(host: host, text: notes.note(forURL: t.url)?.text ?? "",
                                                                 onChange: { [weak self] text in self?.notes.set(url: t.url, title: t.displayTitle, text: text) },
                                                                 onClose: { [weak pop] in pop?.performClose(nil) }))
        host_.sizingOptions = [.preferredContentSize]
        pop.contentViewController = host_
        notePopover = pop
        pop.show(relativeTo: addressField.bounds, of: addressField, preferredEdge: .maxY)
    }

    /// When a page with a note finishes loading, show the note.
    private func showNoteIfAny(_ id: UUID) {
        guard notes.isPersistent, id == store.activeTabID, let t = store.tab(id), let n = notes.note(forURL: t.url) else { return }
        ToastView.show(in: webHost, message: "📝 " + String(n.text.prefix(120)), symbol: "note.text", actionTitle: "Edit", duration: 8) { [weak self] in self?.addNote(nil) }
    }

    // MARK: Remembering pages

    /// Keeps a short piece of each page's text next to its history entry, so you can find "that article about…" by what it says.
    private func rememberPageText(_ id: UUID) {
        guard !isPrivate, storage != nil, settings.rememberPageText, let l = live[id], let url = store.tab(id)?.url,
              url.hasPrefix("http"), pdfOverlays[id] == nil else { return }
        let js = """
        (() => {
          if (document.querySelector('input[type=password]')) return '';
          const meta = (document.querySelector('meta[name=description], meta[property="og:description"]') || {}).content || '';
          const h = Array.from(document.querySelectorAll('h1, h2')).slice(0, 3).map(e => e.innerText.trim()).join(' · ');
          const root = document.querySelector('article, main') || document.body;
          const body = Array.from(root.querySelectorAll('p')).map(p => p.innerText.trim()).filter(t => t.length > 40).slice(0, 4).join(' ');
          return (meta + ' ' + h + ' ' + body).replace(/\\s+/g, ' ').trim().slice(0, 400);
        })()
        """
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)  // let the page finish drawing
            let params = try? JSONSerialization.data(withJSONObject: ["expression": js, "returnByValue": true])
            guard let self, let raw = try? await l.tab.devTools("Runtime.evaluate", params: params.flatMap { String(data: $0, encoding: .utf8) }),
                  let d = raw.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let text = (o["result"] as? [String: Any])?["value"] as? String, !text.isEmpty else { return }
            self.history.updateSnippet(url: url, snippet: text)
        }
    }

    // MARK: PDF viewer

    private var pdfOverlays: [UUID: PDFViewerOverlay] = [:]

    /// When a page turns out to be a PDF, show it in the native reader.
    private func showPDFIfNeeded(_ id: UUID) {
        guard let l = live[id], let t = store.tab(id), let url = URL(string: t.url), url.scheme == "http" || url.scheme == "https" || url.isFileURL else { return }
        Task { @MainActor [weak self] in
            let params = try? JSONSerialization.data(withJSONObject: ["expression": "document.contentType", "returnByValue": true])
            guard let raw = try? await l.tab.devTools("Runtime.evaluate", params: params.flatMap { String(data: $0, encoding: .utf8) }),
                  raw.contains("application/pdf") else { return }
            guard let data = await PDFFetcher.data(for: url), let self, self.live[id] != nil, self.store.tab(id)?.url == t.url,
                  let overlay = PDFViewerOverlay(data: data, sourceURL: url) else { return }
            self.pdfOverlays.removeValue(forKey: id)?.removeFromSuperview()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            l.container.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: l.container.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: l.container.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: l.container.topAnchor), overlay.bottomAnchor.constraint(equalTo: l.container.bottomAnchor),
            ])
            self.pdfOverlays[id] = overlay
        }
    }

    // MARK: Saved logins

    /// Logins saved in this profile (private windows keep none).
    public lazy var vault = PasswordVault(directory: kind.isPrivate ? nil : storage?.directory)
    private let pageNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var offeredFill: Set<UUID> = []

    /// After a page finishes loading: start watching its login forms, and offer to fill a saved login.
    private func passwordsAfterLoad(_ id: UUID) {
        guard vault.isPersistent, settings.offerToSavePasswords, let l = live[id] else { return }
        let nonce = pageNonce
        Task { @MainActor [weak self] in
            _ = try? await l.tab.devTools("Runtime.evaluate", params: Self.json(["expression": PasswordScripts.capture(nonce: nonce)]))
            guard let self, id == self.store.activeTabID, !self.offeredFill.contains(id),
                  let host = self.store.tab(id).flatMap({ URL(string: $0.url)?.host }), !self.vault.logins(forHost: host).isEmpty,
                  let r = try? await l.tab.devTools("Runtime.evaluate", params: Self.json(["expression": PasswordScripts.hasLoginForm, "returnByValue": true])),
                  r.contains("true") else { return }
            self.offeredFill.insert(id)
            let login = self.vault.logins(forHost: host)[0]
            ToastView.show(in: self.webHost, message: String(localized: "Fill the saved login for \(login.user)?"), symbol: "key.fill", actionTitle: "Fill", duration: 8) { [weak self] in self?.fillLogin(login) }
        }
    }

    private static func json(_ o: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Puts a saved login into the page's form. Only ever on the user's say-so.
    private func fillLogin(_ login: SavedLogin) {
        guard let id = store.activeTabID, let l = live[id], let host = store.tab(id).flatMap({ URL(string: $0.url)?.host }),
              PasswordVault.normalize(host: host) == login.host, let pw = vault.password(for: login) else { return }
        Task { @MainActor in
            _ = try? await l.tab.devTools("Runtime.evaluate", params: Self.json(["expression": PasswordScripts.fill(user: login.user, password: pw)]))
        }
    }

    /// Menu: fills the (most recent) saved login for the current site.
    @objc public func fillSavedLogin(_ s: Any?) {
        guard let id = store.activeTabID, let host = store.tab(id).flatMap({ URL(string: $0.url)?.host }) else { NSSound.beep(); return }
        guard let login = vault.logins(forHost: host).first else {
            ToastView.show(in: webHost, message: "No saved login for this site", symbol: "key", duration: 2.2); return
        }
        fillLogin(login)
    }

    // MARK: Site notifications

    /// Which sites may show notifications ("granted" / "denied"), remembered across launches.
    public var notificationDecisions: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "notificationDecisions") as? [String: String] ?? [:] }
        set {
            UserDefaults.standard.set(newValue, forKey: "notificationDecisions")
            engine.setDocumentStartScript(NotificationShim.script(decisions: newValue))
            let update = "window.__paneNotifDecisions = \(Self.jsonObject(newValue));"
            for l in live.values { Task { _ = try? await l.tab.devTools("Runtime.evaluate", params: Self.json(["expression": update])) } }
        }
    }

    private static func jsonObject(_ d: [String: String]) -> String { (try? JSONSerialization.data(withJSONObject: d)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" }

    private var lastNotifications: [UUID: [Date]] = [:]

    private func handleNotificationMessage(_ message: String, tabID id: UUID, tab: BrowserTab) {
        guard let data = String(message.dropFirst("__pane-notif:".count)).data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = o["k"] as? String, let url = store.tab(id).flatMap({ URL(string: $0.url) }), let host = url.host else { return }
        let origin = "\(url.scheme ?? "https")://\(host)" + (url.port.map { ":\($0)" } ?? "")
        switch kind {
        case "ask":
            guard let window else { return }
            if let known = notificationDecisions[origin] { answerNotificationRequest(known, on: tab); return }
            if isPrivate { answerNotificationRequest("denied", on: tab); return }
            if let forced = ProcessInfo.processInfo.environment["PANE_DEBUG_NOTIF"] {  // test runs answer without a dialog
                var all = notificationDecisions; all[origin] = forced; notificationDecisions = all; answerNotificationRequest(forced, on: tab); return
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(host)” wants to show notifications")
            alert.informativeText = tr("They appear in the macOS notification centre while this page is open in Pane.")
            alert.addButton(withTitle: tr("Allow")); alert.addButton(withTitle: tr("Don't Allow"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                let decision = response == .alertFirstButtonReturn ? "granted" : "denied"
                var all = self.notificationDecisions; all[origin] = decision; self.notificationDecisions = all
                self.answerNotificationRequest(decision, on: tab)
            }
        case "show":
            guard notificationDecisions[origin] == "granted" else { return }
            var recent = (lastNotifications[id] ?? []).filter { Date().timeIntervalSince($0) < 60 }
            guard recent.count < 6 else { return }   // a page can't flood the notification centre
            recent.append(Date()); lastNotifications[id] = recent
            let content = UNMutableNotificationContent()
            content.title = String((o["title"] as? String ?? host).prefix(120))
            content.subtitle = host
            content.body = String((o["body"] as? String ?? "").prefix(300))
            content.sound = .default
            content.userInfo = ["tab": id.uuidString, "url": store.tab(id)?.url ?? ""]
            guard ProcessInfo.processInfo.environment["PANE_DEBUG_NO_NOTIFY"] == nil else { debugNotifications.append(content.title); return }
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { return }
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        default: break
        }
    }

    var debugNotifications: [String] = []

    private func answerNotificationRequest(_ decision: String, on tab: BrowserTab) {
        Task { _ = try? await tab.devTools("Runtime.evaluate", params: Self.json(["expression": "window.__paneNotifAnswer && window.__paneNotifAnswer('\(decision)')"])) }
    }

    /// A notification was clicked: bring the tab (or the address) forward.
    public func openNotification(tabID: String?, url: String) {
        window?.makeKeyAndOrderFront(nil)
        if let s = tabID, let id = UUID(uuidString: s), store.tab(id) != nil { activate(id) } else if !url.isEmpty { open(url, newTab: true) }
    }

    public func tab(_ tab: BrowserTab, didSendPageMessage message: String) {
        if message.hasPrefix("__pane-notif:") {
            if let id = tabIDs[ObjectIdentifier(tab as AnyObject)] { handleNotificationMessage(message, tabID: id, tab: tab) }
            return
        }
        guard !kind.isPrivate, vault.isPersistent, settings.offerToSavePasswords, let id = tabIDs[ObjectIdentifier(tab as AnyObject)],
              message.hasPrefix("__pane:\(pageNonce):"),
              let data = String(message.dropFirst("__pane:\(pageNonce):".count)).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = o["u"] as? String, let password = o["p"] as? String, !password.isEmpty, user.count < 200, password.count < 500,
              let host = store.tab(id).flatMap({ URL(string: $0.url)?.host }) else { return }
        let outcome = vault.outcome(host: host, user: user, password: password)
        guard outcome != .unchanged else { return }
        if ProcessInfo.processInfo.environment["PANE_DEBUG_PW"] != nil { vault.save(host: host, user: user, password: password); return }
        let name = PasswordVault.normalize(host: host)
        let text = user.isEmpty ? String(localized: "Save the password for \(name)?")
            : (outcome == .update ? String(localized: "Update the password for \(user) on \(name)?") : String(localized: "Save the password for \(user) on \(name)?"))
        ToastView.show(in: webHost, message: text, symbol: "key.fill", actionTitle: outcome == .update ? "Update" : "Save", duration: 12) { [weak self] in
            self?.vault.save(host: host, user: user, password: password)
        }
    }

    // MARK: Page watches

    func startWatching() {
        watchTimer?.invalidate()
        guard !kind.isPrivate else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["PANE_OFFSCREEN"] == nil else { return }
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self.map { w in Task { @MainActor in await w.watches.checkAll() } } }
        }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated { self.map { w in Task { @MainActor in await w.watches.checkAll() } } }
        }
    }

    private func watchTriggered(_ w: PageWatch) {
        let what: String
        switch w.mode {
        case .appears: what = String(localized: "“\(w.text)” appeared on the page")
        case .disappears: what = String(localized: "“\(w.text)” is gone from the page")
        case .changes: what = tr("The page has changed")
        case .below: what = String(localized: "the number after “\(w.text)” fell below \(w.threshold.map { String($0) } ?? "")")
        case .above: what = String(localized: "the number after “\(w.text)” rose above \(w.threshold.map { String($0) } ?? "")")
        }
        ToastView.show(in: webHost, message: "\(w.title): \(what)", symbol: "eye.fill", actionTitle: "Open", duration: 10) { [weak self] in self?.open(w.url, newTab: true) }
        let content = UNMutableNotificationContent()
        content.title = w.title
        content.body = what
        content.sound = .default
        content.userInfo = ["url": w.url]
        guard ProcessInfo.processInfo.environment["PANE_DEBUG_NO_NOTIFY"] == nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: w.id.uuidString, content: content, trigger: nil))
        }
    }

    /// Called when the user clicks a notification.
    public func openFromNotification(_ url: String) { window?.makeKeyAndOrderFront(nil); open(url, newTab: true) }

    // MARK: Quick commands

    private func saveMacro(_ prompt: String) {
        let alert = NSAlert()
        alert.messageText = tr("Save as quick command")
        alert.informativeText = tr("Give it a short name. It will appear at the top of the agent panel.")
        alert.addButton(withTitle: tr("Save")); alert.addButton(withTitle: tr("Cancel"))
        let field = NSTextField(string: String(prompt.prefix(28)))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if assistantModel.macros.add(name: field.stringValue, prompt: prompt) {
            ToastView.show(in: webHost, message: "Saved as a quick command", symbol: "bolt.fill", duration: 2)
        } else { NSSound.beep() }
    }

    // MARK: History window

    private var libraryWindow: LibraryWindowController?

    /// History and downloads in a window of their own (⌘Y).
    @objc public func showHistory(_ s: Any?) { showLibrary(.history) }
    private func showLibrary(_ section: LibraryModel.Section) {
        if libraryWindow == nil {
            let m = LibraryModel(downloads: downloads)
            m.onOpen = { [weak self] url in self?.open(url, newTab: true) }
            m.onDelete = { [weak self] url in self?.history.remove(url: url); self?.libraryWindow?.model.entries = self?.history.entries ?? [] }
            m.onClearHistory = { [weak self] in self?.history.clear(); self?.libraryWindow?.model.entries = [] }
            libraryWindow = LibraryWindowController(model: m)
        }
        libraryWindow?.model.entries = history.entries
        libraryWindow?.model.section = section
        libraryWindow?.show()
    }

    // MARK: What's new

    private var whatsNewPopover: NSPopover?

    /// After an update, tells the user once what changed.
    private func showWhatsNewIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard !kind.isPrivate, env["PANE_OFFSCREEN"] == nil, env["PANE_SUPPORT_DIR"] == nil,
              let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init),
              let news = WhatsNew.pending(currentBuild: build) else { return }
        WhatsNew.clear()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                let pop = NSPopover()
                pop.behavior = .transient
                let anchor: NSView = self.modeControl
                let host = NSHostingController(rootView: UpdateCompleteView(
                    title: news.title,
                    onSeeWhatsNew: { [weak self, weak pop] in
                        pop?.performClose(nil)
                        guard let self else { return }
                        let card = NSPopover(); card.behavior = .transient
                        let h = NSHostingController(rootView: WhatsNewView(title: news.title, lines: news.lines) { [weak card] in card?.performClose(nil) })
                        h.sizingOptions = [.preferredContentSize]
                        card.contentViewController = h
                        self.whatsNewPopover = card
                        card.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
                    },
                    onShare: { [weak self, weak pop] in
                        pop?.performClose(nil)
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("https://pane.2-26-86-13.sslip.io/Pane.dmg", forType: .string)
                        if let self { ToastView.show(in: self.webHost, message: "Download link copied — send it to a friend", symbol: "link", duration: 3) }
                    },
                    onClose: { [weak pop] in pop?.performClose(nil) }))
                host.sizingOptions = [.preferredContentSize]
                pop.contentViewController = host
                self.whatsNewPopover = pop
                pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
            }
        }
    }

    @objc public func toggleDownloads(_ sender: Any?) {
        if let p = downloadsPopover, p.isShown { p.performClose(nil); return }
        guard !downloadsButton.isHidden || !downloads.items.isEmpty else { return }
        let view = DownloadsPopoverView(
            store: downloads,
            onShow: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0.path)]) },
            onOpen: { NSWorkspace.shared.open(URL(fileURLWithPath: $0.path)) },
            onCancel: { [weak self] item in
                // Any live tab can cancel it: the engine tracks downloads per browser, so ask them all.
                self?.live.values.forEach { $0.tab.cancelDownload(id: item.engineID) }
            })
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: view)
        downloadsPopover = pop
        pop.show(relativeTo: downloadsButton.bounds, of: downloadsButton, preferredEdge: .maxY)
    }

    // MARK: Printing

    @objc public func printPage(_ sender: Any?) {
        guard let tab = activeLive?.tab else { NSSound.beep(); return }
        tab.printPage()
    }

    @objc public func savePageAsPDF(_ sender: Any?) {
        guard let id = store.activeTabID, let tab = live[id]?.tab, let t = store.tab(id) else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = t.displayTitle.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        panel.nameFieldStringValue = (base.isEmpty ? tr("Page") : base) + ".pdf"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let ok = await tab.savePDF(to: url)
            if ok {
                ToastView.show(in: webHost, message: String(localized: "Saved \(url.lastPathComponent)"), symbol: "doc.richtext.fill", actionTitle: "Show in Finder", duration: 6) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } else {
                ToastView.show(in: webHost, message: "Couldn't save the PDF", symbol: "exclamationmark.triangle.fill", duration: 3)
            }
        }
    }

    // MARK: Find in page (⌘F)

    @objc public func showFind(_ sender: Any?) {
        guard activeLive != nil else { NSSound.beep(); return }
        if let pdf = store.activeTabID.flatMap({ pdfOverlays[$0] }) { pdf.focusSearch(); return }  // a PDF has its own search
        if findBar == nil {
            let bar = FindBarView()
            bar.onQuery = { [weak self] text, forward, next in self?.runFind(text, forward: forward, next: next) }
            bar.onClose = { [weak self] in self?.closeFind() }
            bar.attach(to: webHost)
            findBar = bar
        }
        findBar?.focus()
    }

    @objc public func findNextMatch(_ sender: Any?) { if findBar == nil { showFind(nil) } else { findBar?.nextMatch() } }
    @objc public func findPreviousMatch(_ sender: Any?) { if findBar == nil { showFind(nil) } else { findBar?.previous() } }

    private func runFind(_ text: String, forward: Bool, next: Bool) {
        guard let tab = activeLive?.tab else { return }
        if text.isEmpty { tab.stopFinding(); findBar?.setResult(count: 0, active: 0); return }
        tab.find(text, forward: forward, matchCase: false, next: next)
    }

    private func closeFind() {
        activeLive?.tab.stopFinding()
        findBar?.dismiss()
        findBar = nil
        if let c = store.activeTabID.flatMap({ live[$0]?.container }) { window?.makeFirstResponder(c.subviews.first) }
    }

    // MARK: Command palette (⌘K)

    @objc public func togglePalette(_ sender: Any?) {
        if palette != nil { closePalette(); return }
        let p = CommandPaletteView(
            provider: search,
            items: { [weak self] in self?.searchItems() ?? [] },
            icon: { [weak self] url in self?.faviconCache.image(for: url) },
            onChoose: { [weak self] choice, newTab in self?.paletteChose(choice, newTab: newTab) },
            onClose: { [weak self] in self?.closePalette() },
            engineName: { [weak self] in self?.settings.searchEngine.name ?? tr("the web") })
        palette = p
        p.present(in: rootView)
    }

    /// Debug aid (PANE_DEBUG_PALETTE): open the palette with a query already typed.
    public func debugShowPalette(query: String) { togglePalette(nil); palette?.debugSetQuery(query) }

    private func closePalette() {
        palette?.dismiss()
        palette = nil
        if let c = store.activeTabID.flatMap({ live[$0]?.container }) { window?.makeFirstResponder(c.subviews.first) }
    }

    func searchItems() -> [SearchItem] {
        var out: [SearchItem] = store.tabs.filter { !$0.url.isEmpty }.map {
            SearchItem(id: "tab:\($0.id)", kind: .tab, title: $0.displayTitle, url: $0.url, tabID: $0.id, lastUsed: $0.lastActive)
        }
        func walk(_ n: BookmarkNode) {
            if let u = n.url { out.append(SearchItem(id: "bm:\(n.id)", kind: .bookmark, title: n.displayTitle, url: u)) }
            n.children.forEach(walk)
        }
        bookmarks.roots.forEach(walk)
        out += notes.notes.map { SearchItem(id: "note:\($0.id)", kind: .note, title: String($0.text.prefix(80)), url: $0.url, lastUsed: $0.updated, detail: $0.title) }
        out += history.entries.prefix(2000).map {
            SearchItem(id: "hist:\($0.url)", kind: .history, title: $0.title, url: $0.url, lastUsed: $0.lastVisit, visits: $0.visits, detail: $0.snippet ?? "")
        }
        return out
    }

    private func paletteChose(_ choice: PaletteChoice, newTab: Bool) {
        closePalette()
        switch choice {
        case .item(let item):
            if item.kind == .tab, let id = item.tabID, !newTab { activate(id) }
            else if item.kind == .note, !newTab, let t = store.tabs.first(where: { normalizedURL($0.url) == normalizedURL(item.url) }) { activate(t.id) }
            else { open(item.url, newTab: newTab) }
        case .web(let q):
            if let url = AddressInput.resolve(q, engine: settings.searchEngine) { open(url, newTab: newTab) }
        }
    }

    func open(_ url: String, newTab: Bool) {
        if newTab {
            store.addTab(url: url, groupID: store.activeTabID.flatMap { store.tab($0)?.groupID })
            showActive()
        } else {
            navigate(url)
        }
    }

    // MARK: Bookmarks

    @objc private func sidebarModeChanged(_ s: NSSegmentedControl) { showSidebarMode(s.selectedSegment) }

    private func showSidebarMode(_ mode: Int) {
        modeControl.selectedSegment = mode
        let incoming: NSView = mode == 0 ? sidebar : bookmarksSidebar
        let outgoing: NSView = mode == 0 ? bookmarksSidebar : sidebar
        guard incoming.isHidden else { return }
        incoming.alphaValue = 0
        incoming.isHidden = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.01 : 0.2
            incoming.animator().alphaValue = 1
            outgoing.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { outgoing.isHidden = true; outgoing.alphaValue = 1 } })
    }

    @objc public func showAllBookmarks(_ sender: Any?) {
        if sidebarCollapsed { toggleSidebar() }
        showSidebarMode(1)
    }

    @objc public func bookmarkThisPage(_ sender: Any?) {
        if isPrivate {
            ToastView.show(in: webHost, message: "Bookmarks can't be changed in a private window", symbol: "lock.shield.fill", duration: 2.5)
            return
        }
        guard let id = store.activeTabID, let t = store.tab(id), !t.url.isEmpty, t.url != "about:blank" else { NSSound.beep(); return }
        let title = t.displayTitle, url = t.url
        if bookmarks.toggle(title: title, url: url) {
            ToastView.show(in: webHost, message: "Added to Bookmarks Bar", symbol: "star.fill", actionTitle: "Undo") { [weak self] in
                if let b = self?.bookmarks.bookmark(forURL: url) { self?.bookmarks.remove(b.id) }
            }
        } else {
            ToastView.show(in: webHost, message: "Bookmark removed", symbol: "star.slash", actionTitle: "Undo") { [weak self] in
                self?.bookmarks.add(title: title, url: url)
            }
        }
    }

    @objc public func toggleBookmarksBar(_ sender: Any?) { settings.showBookmarksBar.toggle() }  // settingChanged does the work

    private func setBookmarksBar(visible: Bool) {
        bookmarksBarVisible = visible
        if bookmarksBarVisible { barGlass.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            barHeight.animator().constant = bookmarksBarVisible ? 24 : 0
            barTop.animator().constant = bookmarksBarVisible ? 6 : 0
            webTop.animator().constant = bookmarksBarVisible ? 6 : 8
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if let self, !self.bookmarksBarVisible { self.barGlass.isHidden = true } }
        })
    }

    /// A small bouncing symbol on top of a toolbar button (a "yes, that worked" nudge).
    private func pulse(_ view: NSView, symbol: String, tint: NSColor) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, view.window != nil else { return }
        let iv = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        iv.contentTintColor = tint
        iv.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        iv.frame = view.bounds
        iv.imageAlignment = .alignCenter
        view.addSubview(iv)
        iv.addSymbolEffect(.bounce, options: .repeat(1))
        iv.wantsLayer = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; iv.animator().alphaValue = 0 }, completionHandler: { MainActor.assumeIsolated { iv.removeFromSuperview() } })
        }
    }

    private var starWasOn = false
    private var lastDoneDownloads = 0
    private func updateStar() {
        let url = store.activeTabID.flatMap { store.tab($0)?.url } ?? ""
        let on = !url.isEmpty && bookmarks.isBookmarked(url)
        starButton.image = NSImage(systemSymbolName: on ? "star.fill" : "star", accessibilityDescription: nil)
        if on && !starWasOn { pulse(starButton, symbol: "star.fill", tint: .systemYellow) }
        starWasOn = on
        starButton.contentTintColor = on ? .systemYellow : .secondaryLabelColor
        let label = tr(on ? "Remove Bookmark" : "Bookmark This Page")
        starButton.toolTip = ShortcutCatalog.hint(label, "Bookmark This Page")
        starButton.setAccessibilityLabel(label)
    }

    private func openBookmark(_ n: BookmarkNode, newTab: Bool) {
        guard let url = n.url else { return }
        if newTab {
            store.addTab(url: url, groupID: store.activeTabID.flatMap { store.tab($0)?.groupID })
            showActive()
        } else {
            navigate(url)
        }
    }

    private func bookmarkTab(_ id: UUID, in folder: UUID?, before: UUID?) {
        guard let t = store.tab(id), !t.url.isEmpty else { return }
        if let existing = bookmarks.bookmark(forURL: t.url) {
            bookmarks.move(existing.id, toFolder: folder ?? bookmarks.bar.id, before: before)
        } else {
            bookmarks.add(title: t.displayTitle, url: t.url, toFolder: folder, before: before)
        }
    }

    private func bookmarkMenu(for n: BookmarkNode) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; i.representedObject = n.id; m.addItem(i)
        }
        if !n.isFolder { add(tr("Open in New Tab"), #selector(menuOpenBookmarkInNewTab(_:))) }
        add(tr("Rename…"), #selector(menuRenameBookmark(_:)))
        add(tr("Delete"), #selector(menuDeleteBookmark(_:)))
        return m
    }
    @objc private func menuOpenBookmarkInNewTab(_ s: NSMenuItem) {
        if let id = s.representedObject as? UUID, let n = bookmarks.node(id) { openBookmark(n, newTab: true) }
    }
    @objc private func menuDeleteBookmark(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { bookmarks.remove(id) } }
    @objc private func menuRenameBookmark(_ s: NSMenuItem) {
        guard let id = s.representedObject as? UUID, let n = bookmarks.node(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.addButton(withTitle: tr("OK")); alert.addButton(withTitle: tr("Cancel"))
        let f = NSTextField(string: n.displayTitle)
        f.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = f
        alert.window.initialFirstResponder = f
        if alert.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty { bookmarks.rename(id, to: f.stringValue) }
    }

    // MARK: Import

    public var importerNames: [String] { importers.map(\.name) }

    private func makeImportMenu() -> NSMenu {
        let m = NSMenu()
        for (i, imp) in importers.enumerated() {
            let item = NSMenuItem(title: String(localized: "From \(imp.name)…"), action: #selector(importMenuItem(_:)), keyEquivalent: "")
            item.target = self; item.tag = i
            m.addItem(item)
        }
        return m
    }
    @objc private func importMenuItem(_ s: NSMenuItem) { importBookmarks(from: s.tag) }

    public func importBookmarks(from index: Int) {
        guard importers.indices.contains(index) else { return }
        let imp = importers[index]
        var nodes: [BookmarkNode] = []
        for file in imp.candidateFiles() {
            if let data = try? Data(contentsOf: file), let parsed = try? imp.parse(data) { nodes += parsed }
        }
        if nodes.isEmpty {
            // Access to the default location was refused or the file is missing: let the user point at it.
            let panel = NSOpenPanel()
            panel.directoryURL = imp.openPanelDirectory
            panel.message = imp.openPanelMessage
            panel.prompt = tr("Import")
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.showsHiddenFiles = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                nodes = try imp.parse(try Data(contentsOf: url))
            } catch {
                showAlert(String(localized: "Couldn't import from \(imp.name)"), String(localized: "That file isn't a valid \(imp.name) bookmarks file."))
                return
            }
        }
        let n = bookmarks.importTree(nodes, folderName: String(localized: "Imported from \(imp.name)"))
        if n == 0 { showAlert("Nothing to import", String(localized: "No bookmarks were found in the \(imp.name) data.")) }
        else { showAllBookmarks(nil); showAlert(String(localized: "Imported \(String(n)) bookmarks"), String(localized: "They are in All Bookmarks › Other Bookmarks › Imported from \(imp.name).")) }
    }

    private func showAlert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = tr(title); a.informativeText = tr(text); a.runModal()
    }

    // MARK: Tab runtime

    var activeLive: Live? { store.activeTabID.flatMap { live[$0] } }

    private func ensureLive(_ id: UUID) {
        guard live[id] == nil, let item = store.tab(id) else { return }
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        webHost.addSubview(container)
        let lead = container.leadingAnchor.constraint(equalTo: webHost.leadingAnchor)
        let trail = container.trailingAnchor.constraint(equalTo: webHost.trailingAnchor)
        let halfLead = container.leadingAnchor.constraint(equalTo: webHost.centerXAnchor, constant: 4)
        let halfTrail = container.trailingAnchor.constraint(equalTo: webHost.centerXAnchor, constant: -4)
        NSLayoutConstraint.activate([
            lead, trail,
            container.topAnchor.constraint(equalTo: webHost.topAnchor),
            container.bottomAnchor.constraint(equalTo: webHost.bottomAnchor),
        ])
        webHost.layoutSubtreeIfNeeded()
        let tab = engine.makeTab(url: item.url.isEmpty ? settings.newTabURL : item.url, in: container, profile: id == agentPrivateTabID ? agentPrivateProfile : profile)
        tab.delegate = self
        tabIDs[ObjectIdentifier(tab as AnyObject)] = id
        live[id] = Live(tab: tab, container: container, leading: lead, trailing: trail, halfLeading: halfLead, halfTrailing: halfTrail)
        webHost.addSubview(startHost, positioned: .above, relativeTo: nil)
        webHost.addSubview(agentOverlay, positioned: .above, relativeTo: nil)
        statusBubble.bringToFront()
        agentPill.bringToFront()
        findBar?.bringToFront()
    }

    private func destroyLive(_ id: UUID) {
        guard let l = live.removeValue(forKey: id) else { return }
        tabIDs[ObjectIdentifier(l.tab as AnyObject)] = nil
        l.tab.delegate = nil
        // The page's view must outlive the engine's use of it: remove it only once the engine says it has let go.
        l.container.isHidden = true
        let container = l.container
        l.tab.close { container.removeFromSuperview() }
        navState[id] = nil
        audible.remove(id)
        muted.remove(id)
        crashOverlays.removeValue(forKey: id)?.removeFromSuperview()
        pdfOverlays.removeValue(forKey: id)?.removeFromSuperview()
    }

    /// Shows the active tab's page (creating it lazily) and refreshes the chrome.
    func showActive() {
        guard let id = store.activeTabID else { return }
        let isStart = store.tab(id)?.url.isEmpty ?? false
        if !isStart { ensureLive(id) }  // a start-page tab needs no web view at all
        statusBubble.set("")
        if findBar != nil { live.values.forEach { $0.tab.stopFinding() }; findBar?.dismiss(); findBar = nil }
        // Split view: the active page on the left, a second page on the right.
        if splitID == id { splitID = shownActiveID.flatMap { store.tab($0) != nil && $0 != id ? $0 : nil } }  // picked the right-hand page: swap sides
        if let s = splitID, store.tab(s) == nil || s == id { splitID = nil }
        let secondary = isStart ? nil : splitID
        if let s = secondary { ensureLive(s) }
        for (lid, l) in live {
            let visible = (lid == id && !isStart) || lid == secondary
            l.container.isHidden = !visible
            l.tab.setHidden(!visible)
            let left = secondary != nil && lid == id, right = lid == secondary
            l.trailing.isActive = !left; l.halfTrailing.isActive = left
            l.leading.isActive = !right; l.halfLeading.isActive = right
        }
        shownActiveID = id
        startHost.isHidden = !isStart
        if isStart { refreshStartPage() }
        refreshChrome()
        updateSidebarTint()
        if assistantOpen { refreshAssistantModel() }
    }

    /// Applies the chosen colour theme to the window glass, the start page and the assistant.
    private func applyTheme() {
        let theme = settings.theme
        if #available(macOS 26.0, *), let g = windowGlass as? NSGlassEffectView {
            g.tintColor = isPrivate ? NSColor.systemPurple.withAlphaComponent(0.22) : theme.nsColor?.withAlphaComponent(0.14)
        }
        startModel.accent = theme.color
        assistantModel?.accent = theme.color
        updateSidebarTint()
    }

    /// Washes the sidebar with the colour of the page you are on (from its icon). Off when the setting is off.
    private func updateSidebarTint() {
        guard #available(macOS 26.0, *), let glass = sidebarSurface as? NSGlassEffectView else { return }
        var color: NSColor?
        if settings.sidebarTint, let id = store.activeTabID, let icon = favicons[id] ?? store.tab(id).flatMap({ faviconCache.image(for: $0.url) }) {
            color = DominantColor.of(icon)
        }
        let target = color?.withAlphaComponent(0.28) ?? settings.theme.nsColor?.withAlphaComponent(0.22)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { glass.tintColor = target; return }
        let t = CATransition(); t.type = .fade; t.duration = 0.5
        glass.layer?.add(t, forKey: "tint")
        glass.tintColor = target
    }

    // MARK: Start page

    private func refreshStartPage() {
        let favs = StartPageContent.favorites(bar: bookmarks.bar.children, history: history.entries)
        let rec = StartPageContent.recents(history: history.entries, excluding: favs)
        func tiles(_ s: [StartPageContent.Site]) -> [StartPageModel.Tile] {
            s.map { StartPageModel.Tile(id: $0.url, title: $0.title, url: $0.url, icon: faviconCache.image(for: $0.url)) }
        }
        startModel.favorites = tiles(favs)
        startModel.recents = tiles(rec)
        startModel.engineName = settings.searchEngine.name
        startModel.isPrivate = isPrivate
    }

    /// Loads `url` in the current tab, creating its web view first if it was showing the start page.
    func navigate(_ url: String) {
        guard let id = store.activeTabID else { return }
        if let l = live[id] { l.tab.load(url) } else { store.update(id, url: url); showActive() }
    }

    private func refreshChrome() {
        guard let id = store.activeTabID, let t = store.tab(id) else { return }
        window?.title = t.displayTitle
        setAddress(t.url)
        applyNav(navState[id] ?? LoadingState())
        updateStar()
    }

    private func applyNav(_ state: LoadingState) {
        loadingBar.setActive(state.isLoading)
        back.isEnabled = state.canGoBack
        forward.isEnabled = state.canGoForward
        let symbol = state.isLoading ? "xmark" : "arrow.clockwise"
        let label = tr(state.isLoading ? "Stop" : "Reload")
        reloadButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        reloadButton.toolTip = state.isLoading ? tr("Stop") : ShortcutCatalog.hint("Reload", "Reload")
        reloadButton.setAccessibilityLabel(label)
    }

    private func sleepStaleTabs() {
        // A tab that is playing audio stays awake even if you haven't looked at it for a while.
        let interval = sleepOverride ?? TimeInterval(settings.sleepMinutes * 60)
        guard interval > 0 else { return }  // "Never"
        for id in store.sleepStale(olderThan: interval, excluding: audible.union(splitID.map { [$0] } ?? [])) { destroyLive(id) }
    }

    // MARK: TabCommands

    func newTab(inGroup group: UUID?) {
        store.addTab(url: settings.newTabURL, groupID: group)
        showActive()
        if store.activeTabID.flatMap({ store.tab($0)?.url.isEmpty }) == true {
            window?.makeFirstResponder(nil)
            startModel.focusToken += 1  // the start page's own search field takes the cursor
        } else {
            focusAddressBar()
        }
    }

    func activate(_ id: UUID) {
        guard store.tab(id) != nil else { return }
        store.activate(id)
        showActive()
    }

    func close(_ id: UUID) {
        guard store.tab(id) != nil else { return }
        if store.tabs.count == 1 { destroyLive(id); window?.close(); return }
        // The row fades first so the list doesn't just snap shut.
        sidebar.fadeOut(id) { [weak self] in self?.performClose(id) }
    }

    private func performClose(_ id: UUID) {
        guard store.tab(id) != nil, store.tabs.count > 1 else { return }
        let wasActive = id == store.activeTabID
        if let t = store.tab(id) { closedTabs.push(.init(url: t.url, title: t.title, groupID: t.groupID)) }
        store.close(id)
        destroyLive(id)
        favicons[id] = nil
        if wasActive { showActive() }
    }

    func duplicate(_ id: UUID) {
        guard let t = store.tab(id), !t.url.isEmpty else { return }
        store.addTab(url: t.url, groupID: t.groupID)
        showActive()
    }

    func closeOthers(_ id: UUID) {
        for t in store.tabs where t.id != id && !t.isPinned { close(t.id) }
        activate(id)
    }

    func copyLink(_ id: UUID) {
        guard let t = store.tab(id), !t.url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.url, forType: .string)
        ToastView.show(in: webHost, message: "Link copied", symbol: "link", duration: 2)
    }

    func toggleMute(_ id: UUID) {
        let nowMuted = !muted.contains(id)
        if nowMuted { muted.insert(id) } else { muted.remove(id) }
        live[id]?.tab.setMuted(nowMuted)
        sidebar.refreshTab(id)
    }

    func openURL(_ url: String, inGroup group: UUID?) {
        store.addTab(url: url, groupID: group)
        showActive()
    }

    var canReopenClosed: Bool { !closedTabs.isEmpty }
    func reopenClosed() { reopenClosedTab(nil) }
    func sleepInactive() {
        for t in store.tabs where !t.isPinned && !t.isSleeping && t.id != store.activeTabID { sleep(t.id) }
    }

    @objc public func reopenClosedTab(_ sender: Any?) {
        guard let e = closedTabs.pop() else { NSSound.beep(); return }
        let id = store.addTab(url: e.url, groupID: e.groupID)
        store.update(id, title: e.title)
        showActive()
    }

    @objc public func copyPageAddress(_ sender: Any?) { if let id = store.activeTabID { copyLink(id) } }

    func sleep(_ id: UUID) {
        if id == store.activeTabID, let other = store.tabs.first(where: { $0.id != id && !$0.isSleeping }) { activate(other.id) }
        if store.sleep(id) { destroyLive(id) }
    }

    // MARK: Menu / key actions

    @objc public func newTab(_ sender: Any?) { newTab(inGroup: store.activeTabID.flatMap { store.tab($0)?.groupID }) }
    @objc public func closeCurrentTab(_ sender: Any?) { if let id = store.activeTabID { close(id) } }
    @objc public func newGroup(_ sender: Any?) { sidebar.createGroupInteractively() }
    @objc public func togglePinCurrentTab(_ sender: Any?) {
        guard let id = store.activeTabID, let t = store.tab(id) else { return }
        t.isPinned ? store.unpin(id) : store.pin(id)
    }
    @objc public func sleepCurrentTab(_ sender: Any?) { if let id = store.activeTabID { sleep(id) } }
    @objc public func selectNextTab(_ sender: Any?) { cycle(1) }
    @objc public func selectPreviousTab(_ sender: Any?) { cycle(-1) }

    /// ⌘1…⌘8 pick that tab in sidebar order; ⌘9 picks the last one.
    public func selectTab(number: Int) {
        let order = store.pinned + store.ungrouped + store.groups.flatMap { store.tabs(in: $0.id) } + store.sleeping
        guard !order.isEmpty else { return }
        activate((number >= 9 ? order.last! : order[min(number, order.count) - 1]).id)
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === addressField, isEditingAddress else { return }
        let q = addressField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q != addressFull else { suggestions.hide(); return }
        let hits = search.keywordSearch(q, in: searchItems(), limit: 5)
        suggestions.show(hits.map { .hit($0) } + [.web(q)])
        // The search engine's own suggestions follow a moment later, if it has any (they only go out when this is on).
        suggestTask?.cancel()
        guard settings.webSuggestions, !isPrivate || true, !AddressInput.looksLikeAddress(q) else { return }
        let engine = settings.searchEngineID
        suggestTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let found = await WebSuggestions.fetch(q, engineID: engine)
            guard let self, !Task.isCancelled, self.isEditingAddress, self.addressField.stringValue.trimmingCharacters(in: .whitespaces) == q, !found.isEmpty else { return }
            self.suggestions.show(hits.map { .hit($0) } + [.web(q)] + found.map { .suggestion($0) })
        }
    }

    private var suggestTask: Task<Void, Never>?

    private func chooseSuggestion(_ row: AddressSuggestionsView.Row) {
        suggestions.hide()
        window?.makeFirstResponder(nil)
        switch row {
        case .hit(let h): paletteChose(.item(h.item), newTab: false)
        case .web(let q): paletteChose(.web(q), newTab: false)
        case .suggestion(let s): paletteChose(.web(s), newTab: false)
        }
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === addressField else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)) where suggestions.isVisible: suggestions.move(1); return true
        case #selector(NSResponder.moveUp(_:)) where suggestions.isVisible: suggestions.move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if suggestions.isVisible, let row = suggestions.chosenRow { chooseSuggestion(row); return true }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            suggestions.hide()
            addressField.stringValue = addressFull
            window?.makeFirstResponder(nil)
            return true
        default: return false
        }
    }

    private func cycle(_ step: Int) {
        let order = store.pinned + store.ungrouped + store.groups.flatMap { store.tabs(in: $0.id) } + store.sleeping
        guard order.count > 1, let cur = order.firstIndex(where: { $0.id == store.activeTabID }) else { return }
        activate(order[(cur + step + order.count) % order.count].id)
    }

    @objc private func goBack() { activeLive?.tab.goBack() }
    @objc private func goForward() { activeLive?.tab.goForward() }
    @objc private func reload() { activeLive?.tab.reload() }
    @objc public func navigateBack(_ s: Any?) { goBack() }
    @objc public func navigateForward(_ s: Any?) { goForward() }
    @objc public func reloadPage(_ s: Any?) { reload() }

    /// Split view: shows a second page beside the current one (⌥⌘\\ again closes it).
    @objc public func toggleSplit(_ s: Any?) {
        guard let id = store.activeTabID else { return }
        if splitID != nil { splitID = nil; showActive(); return }
        let other = store.tabs.first { $0.id != id && !$0.isSleeping && !$0.url.isEmpty && live[$0.id] != nil }?.id
            ?? store.tabs.first { $0.id != id && !$0.url.isEmpty }?.id
            ?? store.addTab(url: settings.searchEngine.home, activate: false)
        splitID = other
        showActive()
        ToastView.show(in: webHost, message: "Split view — pick another tab to swap the right side", symbol: "rectangle.split.2x1", duration: 2.5)
    }

    private lazy var translator = PageTranslator { [weak self] in self?.assistantSession.makeProvider() }
    private var translating: Task<Void, Never>?

    /// Translates the page into the app's language (and back again on a second press).
    @objc public func translatePage(_ s: Any?) {
        guard let tab = activeLive?.tab else { NSSound.beep(); return }
        guard assistantSession.isConfigured else { if !assistantOpen { toggleAssistant(nil) }; return }
        if translating != nil { translating?.cancel(); translating = nil; return }
        let language = AppLanguage.current.hasPrefix("ru") ? "Russian" : "English"
        ToastView.show(in: webHost, message: "Translating…", symbol: "character.bubble", duration: 30)
        translating = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.translator.toggle(on: tab, into: language) { _, _ in }
            self.translating = nil
            switch outcome {
            case .translated: ToastView.show(in: self.webHost, message: "Translated — press ⌥⌘T again for the original", symbol: "checkmark.circle.fill", duration: 3)
            case .restored: ToastView.show(in: self.webHost, message: "Original text restored", symbol: "arrow.uturn.backward.circle", duration: 2)
            case .nothing: ToastView.show(in: self.webHost, message: "There is no text to translate on this page", symbol: "character.bubble", duration: 2.5)
            case .failed(let why): ToastView.show(in: self.webHost, message: why, symbol: "exclamationmark.triangle.fill", duration: 4)
            }
        }
    }

    /// Picture in picture: floats the biggest playing video above all windows. A second press brings it back.
    @objc public func togglePictureInPicture(_ s: Any?) {
        guard let tab = activeLive?.tab else { NSSound.beep(); return }
        let js = """
        (async () => {
          if (document.pictureInPictureElement) { await document.exitPictureInPicture(); return 'closed'; }
          const vs = Array.from(document.querySelectorAll('video')).filter(v => v.readyState > 0 && !v.disablePictureInPicture);
          vs.sort((a, b) => (!a.paused === !b.paused ? b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight : (a.paused ? 1 : -1)));
          if (!vs.length) return 'none';
          try { await vs[0].requestPictureInPicture(); return 'opened'; } catch (e) { return 'error:' + e.name; }
        })()
        """
        Task { @MainActor in
            let params = try? JSONSerialization.data(withJSONObject: ["expression": js, "awaitPromise": true, "userGesture": true, "returnByValue": true])
            let raw = try? await tab.devTools("Runtime.evaluate", params: params.flatMap { String(data: $0, encoding: .utf8) })
            let result = raw ?? ""
            if result.contains("\"none\"") { ToastView.show(in: webHost, message: "There is no video on this page", symbol: "pip", duration: 2.5) }
            else if result.contains("error:") || raw == nil { ToastView.show(in: webHost, message: "Picture in picture isn't available for this video", symbol: "pip", duration: 3) }
        }
    }

    /// After cookies are gone, pages that were signed in should notice: reload the visible one.
    func liveTabsReload() { activeLive?.tab.reload() }

    // MARK: Swipe between pages

    private var swipeMonitor: Any?

    /// Two-finger (or three-finger) swipe on the trackpad goes back and forward, like in Safari. Turned on in System Settings ▸ Trackpad ▸ "Swipe between pages".
    private func installSwipeNavigation() {
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
            let dx = event.deltaX, sameWindow = event.window
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, sameWindow === self.window, self.settings.swipeNavigation, let tab = self.activeLive?.tab, let id = self.store.activeTabID,
                      self.fullscreenSaved == nil, self.pdfOverlays[id] == nil else { return false }
                if dx > 0, self.navState[id]?.canGoBack == true { self.nudgePage(toward: 1); tab.goBack(); return true }
                if dx < 0, self.navState[id]?.canGoForward == true { self.nudgePage(toward: -1); tab.goForward(); return true }
                return false
            }
            return handled ? nil : event
        }
    }

    /// A short slide of the page in the swipe direction so the gesture feels answered.
    private func nudgePage(toward direction: CGFloat) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = webHost.layer else { return }
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.fromValue = 0; a.toValue = 28 * direction; a.duration = 0.16; a.autoreverses = true
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "swipe-nudge")
    }

    // MARK: Files and sharing

    /// ⌘O: opens a file from this Mac (a page, a PDF, an image…) in a tab.
    @objc public func openFile(_ s: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.html, .xml, .pdf, .image, .plainText, .json, .movie, .audio, .svg]
        panel.message = tr("Choose a file to open in Pane")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url.absoluteString, newTab: store.tab(store.activeTabID ?? UUID())?.url.isEmpty == false)
    }

    /// ⌘S: saves the page, with its images and styles, as one file you can open later.
    @objc public func savePageAs(_ s: Any?) {
        guard let tab = activeLive?.tab, let t = store.activeTabID.flatMap({ store.tab($0) }) else { NSSound.beep(); return }
        Task { @MainActor in
            guard let raw = try? await tab.devTools("Page.captureSnapshot", params: "{\"format\":\"mhtml\"}"), let d = raw.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let text = o["data"] as? String else {
                ToastView.show(in: webHost, message: "Couldn't save the page", symbol: "exclamationmark.triangle.fill", duration: 3); return
            }
            let panel = NSSavePanel()
            let base = t.displayTitle.replacingOccurrences(of: "/", with: "-")
            panel.nameFieldStringValue = (base.isEmpty ? "page" : base) + ".mhtml"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8); ToastView.show(in: webHost, message: String(localized: "Saved \(url.lastPathComponent)"), symbol: "doc.fill", actionTitle: "Show in Finder", duration: 5) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            catch { ToastView.show(in: webHost, message: "Couldn't save the page", symbol: "exclamationmark.triangle.fill", duration: 3) }
        }
    }

    /// Share sheet for the current page (Messages, Mail, AirDrop, Notes…).
    @objc public func sharePage(_ s: Any?) {
        guard let t = store.activeTabID.flatMap({ store.tab($0) }), let url = URL(string: t.url), t.url.hasPrefix("http") else { NSSound.beep(); return }
        NSSharingServicePicker(items: [url]).show(relativeTo: addressField.bounds, of: addressField, preferredEdge: .maxY)
    }

    // MARK: Site information (the padlock)

    private var sitePopover: NSPopover?

    /// Click on the padlock: what this connection is, what the site may do, and a way to forget it.
    @objc func showSiteInfo(_ s: Any?) {
        guard let id = store.activeTabID, let t = store.tab(id), let url = URL(string: t.url), let host = url.host else { return }
        if let p = sitePopover, p.isShown { p.performClose(nil); return }
        let origin = "\(url.scheme ?? "https")://\(host)"
        let granted = grantedPermissions.filter { $0.key.hasPrefix(origin + "|") }.map { (kind: String($0.key.dropFirst(origin.count + 1)), allowed: $0.value) }.sorted { $0.kind < $1.kind }
        let pop = NSPopover(); pop.behavior = .transient
        let host_ = NSHostingController(rootView: SiteInfoView(
            host: host, secure: url.scheme == "https", permissions: granted,
            onReset: { [weak self] kind in self?.grantedPermissions["\(origin)|\(kind)"] = nil },
            onClearCookies: { [weak self, weak pop] in
                guard let self else { return }
                pop?.performClose(nil)
                Task { @MainActor in
                    await self.engine.clearCookies(for: origin, profile: self.profile)
                    self.activeLive?.tab.reload()
                    ToastView.show(in: self.webHost, message: String(localized: "Cookies of \(host) deleted"), symbol: "trash", duration: 3)
                }
            },
            onNote: { [weak self, weak pop] in pop?.performClose(nil); self?.addNote(nil) }))
        host_.sizingOptions = [.preferredContentSize]
        pop.contentViewController = host_
        sitePopover = pop
        pop.show(relativeTo: lockIcon.bounds, of: lockIcon, preferredEdge: .maxY)
    }

    /// Chromium's developer tools for the current page (⌥⌘I).
    @objc public func showDevTools(_ s: Any?) { activeLive?.tab.showDevTools() ?? NSSound.beep() }

    /// The page's source in a new tab (⌥⌘U).
    @objc public func viewSource(_ s: Any?) {
        guard let t = store.activeTabID.flatMap({ store.tab($0) }), t.url.hasPrefix("http") else { NSSound.beep(); return }
        store.addTab(url: "view-source:" + t.url, groupID: t.groupID)
    }

    /// Opens addresses and files handed over by other apps (links clicked in Mail, files dropped on the Dock icon).
    public func openExternal(_ urls: [URL]) {
        for url in urls {
            let s = url.isFileURL ? url.absoluteString : url.absoluteString
            guard url.scheme == "http" || url.scheme == "https" || url.isFileURL else { continue }
            if let id = store.activeTabID, store.tab(id)?.url.isEmpty == true, urls.count == 1 { open(s, newTab: false) } else { open(s, newTab: true) }
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Reader mode: shows the article of the current page in a clean layer (⌥⌘R again, or Esc, closes it).
    @objc public func toggleReader(_ s: Any?) {
        guard let tab = activeLive?.tab else { NSSound.beep(); return }
        Task { @MainActor in
            let params = try? JSONSerialization.data(withJSONObject: ["expression": ReaderScript.source, "returnByValue": true])
            let result = try? await tab.devTools("Runtime.evaluate", params: params.flatMap { String(data: $0, encoding: .utf8) })
            if result?.contains("nothing") == true {
                ToastView.show(in: webHost, message: "There is no article to show on this page", symbol: "doc.text", duration: 2.5)
            }
        }
    }

    /// Opens the assistant (in Ask mode) and asks it for a short summary of the current page.
    @objc public func summarizePage(_ s: Any?) {
        guard assistantSession.isConfigured else {
            if !assistantOpen { toggleAssistant(nil) }
            return
        }
        if !assistantOpen { toggleAssistant(nil) }
        assistantModel.mode = .ask
        assistantModel.includeCurrent = true
        askAssistant(tr("Summarize this page"))
    }
    @objc public func zoomIn(_ s: Any?) { activeLive?.tab.zoom(by: 0.5); showZoom() }
    @objc public func zoomOut(_ s: Any?) { activeLive?.tab.zoom(by: -0.5); showZoom() }
    @objc public func zoomReset(_ s: Any?) { activeLive?.tab.resetZoom(); showZoom() }

    private func showZoom() {
        guard let level = activeLive?.tab.zoomLevel() else { return }
        let percent = Int((pow(1.2, level) * 100).rounded())
        ToastView.show(in: webHost, message: String(localized: "Zoom \(String(percent))%"), symbol: percent >= 100 ? "plus.magnifyingglass" : "minus.magnifyingglass", duration: 1.6)
    }

    @objc private func commitAddress() {
        guard let url = AddressInput.resolve(addressField.stringValue, engine: settings.searchEngine) else { return }
        navigate(url)
        window?.makeFirstResponder(nil)
    }

    public func focusAddressBar() {
        window?.makeFirstResponder(addressField)
        addressField.selectText(nil)
    }

    // MARK: BrowserTabDelegate

    public func tab(_ tab: BrowserTab, didChangeTitle title: String) {
        guard let id = tabIDs[ObjectIdentifier(tab as AnyObject)] else { return }
        store.update(id, title: title)
        if let u = store.tab(id)?.url, !(navState[id]?.isLoading ?? false) { history.updateTitle(url: u, title: title) }
        if id == store.activeTabID { window?.title = store.tab(id)?.displayTitle ?? title }
    }

    public func tab(_ tab: BrowserTab, didChangeURL url: String) {
        guard let id = tabIDs[ObjectIdentifier(tab as AnyObject)] else { return }
        store.update(id, url: url)
        if id == store.activeTabID {
            setAddress(url)
            updateStar()
        }
    }

    public func tab(_ tab: BrowserTab, loadingChanged state: LoadingState) {
        guard let id = tabIDs[ObjectIdentifier(tab as AnyObject)] else { return }
        let wasLoading = navState[id]?.isLoading ?? false
        if state.isLoading { crashOverlays.removeValue(forKey: id)?.removeFromSuperview() }
        navState[id] = state
        if id == store.activeTabID { applyNav(state) }
        if wasLoading != state.isLoading { sidebar.refreshTab(id) }
        if wasLoading, !state.isLoading, !isPrivate, id != agentPrivateTabID, let t = store.tab(id) { history.record(url: t.url, title: t.title) }
        if state.isLoading { pdfOverlays.removeValue(forKey: id)?.removeFromSuperview() }
        if wasLoading, !state.isLoading { offeredFill.remove(id); if id != agentPrivateTabID { passwordsAfterLoad(id); rememberPageText(id); showNoteIfAny(id) }; showPDFIfNeeded(id) }
    }

    public func tab(_ tab: BrowserTab, didChangeFavicon image: NSImage) {
        guard let id = tabIDs[ObjectIdentifier(tab as AnyObject)] else { return }
        favicons[id] = image
        if let u = store.tab(id)?.url { faviconCache.set(image, for: u) }
        sidebar.refreshTab(id)
        if id == store.activeTabID { updateSidebarTint() }
        bookmarksBar.reload()
        bookmarksSidebar.refreshIcons()
    }

    public func tab(_ tab: BrowserTab, audioChanged isPlaying: Bool) {
        guard let id = tabIDs[ObjectIdentifier(tab as AnyObject)] else { return }
        if isPlaying { audible.insert(id) } else { audible.remove(id) }
        sidebar.refreshTab(id)
    }

    public func tab(_ tab: BrowserTab, downloadUpdated info: DownloadInfo) {
        let state: DownloadItem.State = { switch info.state { case .inProgress: .inProgress; case .complete: .complete; case .canceled: .canceled } }()
        let result = downloads.update(engineID: info.id, name: info.name, path: info.path, percent: info.percent,
                                      received: info.received, total: info.total, state: state)
        guard result.justCompleted else { return }
        let url = URL(fileURLWithPath: result.item.path)
        ToastView.show(in: webHost, message: String(localized: "Downloaded \(url.lastPathComponent)"), symbol: "arrow.down.circle.fill",
                       actionTitle: "Show in Finder", duration: 8) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    public func tab(_ tab: BrowserTab, findResultCount count: Int, active: Int) {
        guard let id = tabIDs[ObjectIdentifier(tab as AnyObject)], id == store.activeTabID else { return }
        findBar?.setResult(count: count, active: active)
    }

    public func tab(_ tab: BrowserTab, statusChanged text: String) {
        guard let id = tabIDs[ObjectIdentifier(tab as AnyObject)], id == store.activeTabID else { return }
        statusBubble.set(text)
    }

    // MARK: Right-click menu

    /// A menu item that runs a closure.
    private final class ActionItem: NSMenuItem {
        private let handler: () -> Void
        init(_ title: String, symbol: String? = nil, enabled: Bool = true, bold: Bool = false, _ handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
            isEnabled = enabled
            if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            if bold { attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]) }
        }
        required init(coder: NSCoder) { fatalError() }
        @objc private func fire() { handler() }
    }

    public func tab(_ tab: BrowserTab, showsContextMenu info: ContextMenuInfo) {
        guard let id = tabIDs[ObjectIdentifier(tab as AnyObject)], id == store.activeTabID || id == agentPrivateTabID, let l = live[id], let window else { return }
        let menu = contextMenu(for: info, tab: tab, id: id)
        if let log = ProcessInfo.processInfo.environment["PANE_DEBUG_CONTEXT_LOG"] {  // test runs record the menu instead of showing it
            try? ("link=\(info.link) media=\(String(describing: info.media)) editable=\(info.isEditable) items=\(menu.items.count)").write(toFile: log, atomically: true, encoding: .utf8); return
        }
        menu.popUp(positioning: nil, at: l.container.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: l.container)
    }

    func contextMenu(for info: ContextMenuInfo, tab: BrowserTab, id: UUID) -> NSMenu {
        let page = store.tab(id)?.url ?? info.pageURL
        let menu = NSMenu()
        menu.autoenablesItems = false
        /// `title` is already in the user's language.
        func add(_ title: String, _ symbol: String? = nil, enabled: Bool = true, _ run: @escaping () -> Void) { menu.addItem(ActionItem(title, symbol: symbol, enabled: enabled, run)) }
        func sep() { if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) } }
        func copyText(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

        if !info.misspelledWord.isEmpty {
            for s in info.suggestions { menu.addItem(ActionItem(s, bold: true) { tab.replaceMisspelling(s) }) }
            if info.suggestions.isEmpty { add(tr("No guesses found"), enabled: false) {} }
            add(tr("Add to Dictionary"), "text.book.closed") { tab.addToDictionary(info.misspelledWord) }
            sep()
        }
        if info.hasLink, !info.link.isEmpty {
            add(tr("Open Link in New Tab"), "plus.square.on.square") { [weak self] in self?.open(info.link, newTab: true) }
            add(tr("Open Link in Background Tab"), "square.on.square") { [weak self] in self?.store.addTab(url: info.link, activate: false) }
            sep()
            add(tr("Copy Link Address"), "link") { copyText(info.link) }
            if !info.linkText.isEmpty { add(tr("Copy Link Text"), "textformat") { copyText(info.linkText) } }
            add(tr("Add Link to Bookmarks"), "star") { [weak self] in
                guard let self, !self.isPrivate else { return }
                self.bookmarks.add(title: info.linkText.isEmpty ? (URL(string: info.link)?.host ?? info.link) : info.linkText, url: info.link)
                ToastView.show(in: self.webHost, message: "Added to Bookmarks Bar", symbol: "star.fill", duration: 2)
            }
            add(tr("Download Linked File"), "arrow.down.circle") { tab.downloadURL(info.link) }
            sep()
        }
        if let media = info.media, !info.mediaSource.isEmpty {
            switch media {
            case .image:
                add(tr("Open Image in New Tab"), "photo") { [weak self] in self?.open(info.mediaSource, newTab: true) }
                add(tr("Save Image As…"), "square.and.arrow.down") { tab.downloadURL(info.mediaSource) }
                add(tr("Copy Image"), "doc.on.doc") { Self.copyImage(info.mediaSource) }
                add(tr("Copy Image Address"), "link") { copyText(info.mediaSource) }
                add(tr("Search the Web for This Image"), "magnifyingglass") { [weak self] in
                    self?.open("https://lens.google.com/uploadbyurl?url=" + (info.mediaSource.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""), newTab: true)
                }
            case .video, .audio:
                add(tr(media == .video ? "Open Video in New Tab" : "Open Audio in New Tab"), "play.rectangle") { [weak self] in self?.open(info.mediaSource, newTab: true) }
                add(tr(media == .video ? "Save Video As…" : "Save Audio As…"), "square.and.arrow.down") { tab.downloadURL(info.mediaSource) }
                add(tr(media == .video ? "Copy Video Address" : "Copy Audio Address"), "link") { copyText(info.mediaSource) }
                if media == .video { add(tr("Picture in Picture"), "pip") { [weak self] in self?.togglePictureInPicture(nil) } }
            }
            sep()
        }
        let selection = info.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty {
            let short = selection.count > 24 ? String(selection.prefix(24)) + "…" : selection
            let engineName = settings.searchEngine.name
            add(tr("Copy"), "doc.on.doc") { tab.performEdit(.copy) }
            add(String(localized: "Search \(engineName) for “\(short)”"), "magnifyingglass") { [weak self] in
                guard let self, let url = AddressInput.resolve(selection, engine: self.settings.searchEngine) else { return }
                self.open(url, newTab: true)
            }
            if selection.count < 60, !selection.contains("\n") {
                add(String(localized: "Look Up “\(short)”"), "character.book.closed") {
                    if let q = selection.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed), let u = URL(string: "dict://\(q)") { NSWorkspace.shared.open(u) }
                }
            }
            if assistantSession.isConfigured {
                add(tr("Ask the Assistant About This"), "sparkles") { [weak self] in
                    guard let self else { return }
                    if !self.assistantOpen { self.toggleAssistant(nil) }
                    self.assistantModel.mode = .ask
                    self.assistantSession.send(String(localized: "Explain this: “\(String(selection.prefix(1500)))”"), contexts: [])
                }
            }
            sep()
        }
        if info.isEditable {
            add(tr("Undo"), "arrow.uturn.backward") { tab.performEdit(.undo) }
            add(tr("Redo"), "arrow.uturn.forward") { tab.performEdit(.redo) }
            sep()
            add(tr("Cut"), "scissors", enabled: !selection.isEmpty) { tab.performEdit(.cut) }
            add(tr("Copy"), "doc.on.doc", enabled: !selection.isEmpty) { tab.performEdit(.copy) }
            add(tr("Paste"), "doc.on.clipboard") { tab.performEdit(.paste) }
            add(tr("Paste as Plain Text"), "doc.plaintext") { tab.performEdit(.pasteplain) }
            add(tr("Select All"), "selection.pin.in.out") { tab.performEdit(.selectAll) }
            sep()
        }
        // What you can do with the page itself.
        let state = navState[id] ?? LoadingState()
        if !info.isEditable {
            add(tr("Back"), "chevron.left", enabled: state.canGoBack) { tab.goBack() }
            add(tr("Forward"), "chevron.right", enabled: state.canGoForward) { tab.goForward() }
            add(tr(state.isLoading ? "Stop" : "Reload Page"), state.isLoading ? "xmark" : "arrow.clockwise") { state.isLoading ? tab.stop() : tab.reload() }
            sep()
        }
        if page.hasPrefix("http"), !info.isEditable {
            let marked = bookmarks.isBookmarked(page)
            add(tr(marked ? "Remove Bookmark" : "Bookmark This Page"), marked ? "star.slash" : "star") { [weak self] in self?.bookmarkThisPage(nil) }
            add(tr("Copy Page Address"), "link") { copyText(page) }
            add(tr("Note for This Page…"), "note.text") { [weak self] in self?.addNote(nil) }
            sep()
            add(tr("Translate Page"), "character.bubble", enabled: assistantSession.isConfigured) { [weak self] in self?.translatePage(nil) }
            add(tr("Reader Mode"), "doc.text") { [weak self] in self?.toggleReader(nil) }
            add(tr("Summarize Page"), "sparkles", enabled: assistantSession.isConfigured) { [weak self] in self?.summarizePage(nil) }
            sep()
            add(tr("Save Page as PDF…"), "doc.richtext") { [weak self] in self?.savePageAsPDF(nil) }
            add(tr("Print…"), "printer") { tab.printPage() }
            sep()
            add(tr("View Source"), "chevron.left.forwardslash.chevron.right") { [weak self] in self?.viewSource(nil) }
        }
        add(tr("Inspect Element"), "wrench.and.screwdriver") { tab.showDevTools() }
        return menu
    }

    private static func copyImage(_ source: String) {
        Task.detached {
            var image: NSImage?
            if source.hasPrefix("data:"), let comma = source.firstIndex(of: ","), let d = Data(base64Encoded: String(source[source.index(after: comma)...])) { image = NSImage(data: d) }
            else if let url = URL(string: source), let (d, _) = try? await URLSession.shared.data(from: url) { image = NSImage(data: d) }
            guard let image else { return }
            await MainActor.run { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }
        }
    }

    // MARK: Permissions, sign-in, certificates, fullscreen

    private var grantedPermissions: [String: Bool] = [:]   // "origin|kind" → decision, for this session

    public func tab(_ tab: BrowserTab, requestsPermission origin: String, kinds: [String], decide: @escaping @MainActor (Bool) -> Void) {
        guard let window, !kinds.isEmpty else { decide(false); return }
        if let forced = ProcessInfo.processInfo.environment["PANE_DEBUG_PERMISSIONS"] { decide(forced == "allow"); return }  // test runs answer without a dialog
        let host = URL(string: origin)?.host ?? origin
        let known = kinds.compactMap { grantedPermissions["\(origin)|\($0)"] }
        if known.count == kinds.count { decide(!known.contains(false)); return }
        let words: [String: String] = ["camera": tr("camera"), "microphone": tr("microphone"), "location": tr("location"), "clipboard": tr("clipboard"),
                                       "midi": tr("MIDI devices"), "fonts": tr("installed fonts"), "files": tr("files on this Mac")]
        let what = ListFormatter.localizedString(byJoining: kinds.map { words[$0] ?? $0 })
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(host)” wants to use your \(what)")
        alert.informativeText = tr("You can change this for every site at any time in the page's permissions.")
        alert.addButton(withTitle: tr("Allow")); alert.addButton(withTitle: tr("Don't Allow"))
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let remember = NSButton(checkboxWithTitle: tr("Remember until I quit Pane"), target: nil, action: nil)
        alert.accessoryView = remember
        alert.beginSheetModal(for: window) { [weak self] response in
            let allow = response == .alertFirstButtonReturn
            if remember.state == .on { kinds.forEach { self?.grantedPermissions["\(origin)|\($0)"] = allow } }
            decide(allow)
        }
    }

    public func tab(_ tab: BrowserTab, requestsLoginFor host: String, realm: String, isProxy: Bool, complete: @escaping @MainActor (String?, String?) -> Void) {
        guard let window else { complete(nil, nil); return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign in to \(host)")
        alert.informativeText = realm.isEmpty ? (isProxy ? tr("The proxy server asks for a user name and password.") : tr("The site asks for a user name and password."))
                                              : String(localized: "“\(realm)” asks for a user name and password.")
        alert.addButton(withTitle: tr("Sign In")); alert.addButton(withTitle: tr("Cancel"))
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24)); user.placeholderString = tr("User name")
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); pass.placeholderString = tr("Password")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58)); box.addSubview(user); box.addSubview(pass)
        alert.accessoryView = box
        alert.window.initialFirstResponder = user
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { complete(user.stringValue, pass.stringValue) } else { complete(nil, nil) }
        }
    }

    public func tab(_ tab: BrowserTab, certificateProblemFor url: String, proceed: @escaping @MainActor (Bool) -> Void) {
        guard let window else { proceed(false); return }
        let host = URL(string: url)?.host ?? url
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "The connection to “\(host)” isn't private")
        alert.informativeText = tr("Pane can't confirm this site is who it claims to be. Someone on the network could be reading or changing what you send. Don't enter passwords or card numbers here.")
        alert.addButton(withTitle: tr("Go Back")); alert.addButton(withTitle: tr("Continue Anyway"))
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in proceed(response == .alertSecondButtonReturn) }
    }

    private var fullscreenHost: NSView?
    private var fullscreenSaved: (id: UUID, constraints: [NSLayoutConstraint], enteredWindowFullscreen: Bool)?

    /// A page went fullscreen (a video, a presentation): its view takes the whole window and the window goes fullscreen with it.
    public func tab(_ tab: BrowserTab, fullscreenChanged on: Bool) {
        guard let id = tabIDs[ObjectIdentifier(tab as AnyObject)], let l = live[id], let root = rootView else { return }
        if on, fullscreenSaved == nil {
            let host = NSView()
            host.wantsLayer = true; host.layer?.backgroundColor = NSColor.black.cgColor
            host.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(host)
            NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: root.leadingAnchor), host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                         host.topAnchor.constraint(equalTo: root.topAnchor), host.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
            let pins = webHost.constraints.filter { $0.firstItem === l.container || $0.secondItem === l.container }
            NSLayoutConstraint.deactivate(pins)
            host.addSubview(l.container)
            NSLayoutConstraint.activate([l.container.leadingAnchor.constraint(equalTo: host.leadingAnchor), l.container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                                         l.container.topAnchor.constraint(equalTo: host.topAnchor), l.container.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
            let wasFull = window?.styleMask.contains(.fullScreen) ?? false
            if !wasFull { window?.toggleFullScreen(nil) }
            fullscreenHost = host
            fullscreenSaved = (id, pins, !wasFull)
        } else if !on, let saved = fullscreenSaved, let host = fullscreenHost {
            fullscreenSaved = nil; fullscreenHost = nil
            if let l2 = live[saved.id] {
                l2.container.removeFromSuperview()
                webHost.addSubview(l2.container)
                NSLayoutConstraint.activate(saved.constraints)
            }
            host.removeFromSuperview()
            if saved.enteredWindowFullscreen, window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
            showActive()
        }
    }

    public func tab(_ tab: BrowserTab, processTerminated reason: String) {
        guard let id = tabIDs[ObjectIdentifier(tab as AnyObject)], let live = live[id], crashOverlays[id] == nil else { return }
        let overlay = CrashOverlay(reason: reason) { [weak self] in
            self?.crashOverlays.removeValue(forKey: id)?.removeFromSuperview()
            self?.live[id]?.tab.reload()
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        live.container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: live.container.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: live.container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: live.container.topAnchor), overlay.bottomAnchor.constraint(equalTo: live.container.bottomAnchor),
        ])
        crashOverlays[id] = overlay
    }

    public func tab(_ tab: BrowserTab, requestsNewTabWith url: String) {
        guard let id = tabIDs[ObjectIdentifier(tab as AnyObject)] else { return }
        store.addTab(url: url, groupID: store.tab(id)?.groupID)
        showActive()
    }
}

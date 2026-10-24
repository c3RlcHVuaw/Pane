import AppKit
import UserNotifications
import CEFBridge
import PaneCEF
import PaneEngine
import PaneAssistant
import PaneImport
import PaneModel
import PaneSearch
import PaneSync
import PaneUpdate
import PaneUI

/// Debug aid (PANE_DEBUG_ASSISTANT=demo): a canned streaming answer, so the panel can be photographed without a key.
struct DemoProvider: LLMProvider {
    func stream(system: String, messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        let text = "## Summary\nThis page is **Pane's start page**: a greeting, a search box and your *favorites*.\n\n- Favorites come from your bookmarks bar\n- Recent sites come from history\n\n1. Type in the box to search\n2. Press `⌘K` to search tabs\n\n> Everything stays on this Mac.\n\n```swift\nlet pane = Browser()\n```\nAnything else?"
        return AsyncThrowingStream { c in
            Task { for word in text.split(separator: " ", omittingEmptySubsequences: false) { c.yield(String(word) + " "); try? await Task.sleep(nanoseconds: 8_000_000) }; c.finish() }
        }
    }
}

/// Debug aid (PANE_DEBUG_AGENT=demo): plays a fixed sequence of tool calls against the test page in scratchpad/site,
/// so the whole agent pipeline can be exercised and photographed without a model.
struct DemoAgentProvider: AgentProvider {
    let pageURL: String
    func stream(system: String, messages: [AgentMessage], tools: [ToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        let turn = messages.filter { $0.role == .assistant }.count
        let script: [[AgentEvent]] = [
            [.text("I'll open the test page and fill it in."), .toolCall(id: "d1", name: "navigate", input: #"{"url":"\#(pageURL)"}"#)],
            [.toolCall(id: "d2", name: "get_page_state", input: "{}")],
            [.toolCall(id: "d3", name: "type_text", input: #"{"ref":1,"text":"Pane Tester"}"#)],
            [.toolCall(id: "d4", name: "select_option", input: #"{"ref":2,"option":"Green"}"#)],
            [.toolCall(id: "d5", name: "click", input: #"{"ref":3}"#)],
            [.toolCall(id: "d6", name: "click", input: #"{"ref":4}"#)],
            [.toolCall(id: "d7", name: "get_page_state", input: "{}")],
            [.toolCall(id: "d8", name: "list_tabs", input: "{}")],
            [.toolCall(id: "d9", name: "set_setting", input: #"{"name":"appearance","value":"dark"}"#)],
            [.toolCall(id: "d10", name: "type_text", input: #"{"ref":5,"text":"hunter2"}"#)],
            [.text("Done: I filled in the form, sent it, checked your tabs and switched to dark mode. I did not touch the password field.")],
        ]
        let events = turn < script.count ? script[turn] : []
        return AsyncThrowingStream { c in
            Task { for e in events { c.yield(e); try? await Task.sleep(nanoseconds: 120_000_000) }; c.finish() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    var engine: CEFEngine?
    /// Every open browser window. The first is the main one; it also owns Settings and the update button.
    var controllers: [BrowserWindowController] = []
    var primary: BrowserWindowController? { controllers.first }
    /// The window menu commands act on.
    var active: BrowserWindowController? { (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? controllers.first }
    var dataRoot: URL!
    var env: [String: String] = [:]
    let profiles = ProfilesStore()
    var updater: DefaultAppUpdater?
    var sync: SyncEngine?
    let assistantKey = KeychainSecretStore(account: "assistant-key")
    let bookmarks = BookmarkStore()
    // A test instance (PANE_SUPPORT_DIR) keeps its preferences apart, so it can never change the real app's.
    static let testDefaults: UserDefaults? = ProcessInfo.processInfo.environment["PANE_SUPPORT_DIR"] != nil ? UserDefaults(suiteName: "com.pane.browser.testing") : nil
    let settings = AppSettings(defaults: AppDelegate.testDefaults ?? .standard)
    let account = AccountSession(defaults: AppDelegate.testDefaults ?? .standard)

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        AppIconStyle.apply(settings.appIcon)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Test mode (PANE_SUPPORT_DIR / PANE_OFFSCREEN): a separate profile and a window parked off-screen,
        // so a test instance never touches the real session or steals focus.
        let env = ProcessInfo.processInfo.environment
        let dataRoot = env["PANE_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("Pane")
        let languages: [String] = AppLanguage.current.hasPrefix("ru") ? ["ru-RU", "ru", "en-US", "en"] : ["en-US", "en"]
        SessionStore.shared.configure(file: dataRoot.appendingPathComponent("sessions.json"))
        AutofillStore.shared.configure(file: dataRoot.appendingPathComponent("autofill.json"))
        let extensionsRoot = dataRoot.appendingPathComponent("Extensions")
        ExtensionStore.shared.configure(root: extensionsRoot)
        guard let engine = CEFEngine(cacheDirectory: dataRoot, languages: languages, extensionPaths: ExtensionStore.enabledPaths(root: extensionsRoot)) else {
            let alert = NSAlert()
            alert.messageText = tr("Could not start the Chromium engine")
            alert.informativeText = tr("The CEF framework is missing from the app bundle.")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.engine = engine
        // Did the last run end badly? If so, offer to send an anonymous report once the window is up.
        let testRun = env["PANE_OFFSCREEN"] != nil || env["PANE_SUPPORT_DIR"] != nil
        if !testRun, let previous = CrashReporter.markLaunch(in: dataRoot), let summary = CrashReporter.latestSummary(after: previous) {
            let feed = (Bundle.main.infoDictionary?["PaneSyncURL"] as? String) ?? "https://pane.2-26-86-13.sslip.io"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                MainActor.assumeIsolated { self?.offerCrashReport(summary, to: URL(string: feed + "/api/crash")) }
            }
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = ProcessInfo.processInfo.environment["PANE_UPDATE_FEED"] ?? info["PaneUpdateFeed"] as? String
        if let feed, let feedURL = URL(string: feed) {
            updater = DefaultAppUpdater(feedURL: feedURL, currentBuild: Int(info["CFBundleVersion"] as? String ?? "") ?? 0,
                                        terminate: { NSApp.terminate(nil) })
        }
        let syncBase = env["PANE_SYNC_URL"] ?? info["PaneSyncURL"] as? String ?? "https://pane.2-26-86-13.sslip.io"
        // A test instance (PANE_SUPPORT_DIR / PANE_OFFSCREEN) must never talk to the sync server with the real account's
        // saved sign-in: it would push its test bookmarks and settings into the user's real data. Tests opt in with PANE_SYNC_URL.
        let isTestRun = env["PANE_SUPPORT_DIR"] != nil || env["PANE_OFFSCREEN"] != nil
        if let url = URL(string: syncBase), !isTestRun || env["PANE_SYNC_URL"] != nil {
            let engine = SyncEngine(transport: HTTPTransport(baseURL: url), tokens: KeychainTokenStore(),
                                    stateURL: dataRoot.appendingPathComponent("sync-state.json"),
                                    bookmarks: bookmarks, settings: settings, session: account)
            account.controller = engine
            sync = engine
        }
        self.env = env
        self.dataRoot = dataRoot
        profiles.load(from: dataRoot.appendingPathComponent("profiles.json"))
        profiles.onChange = { [weak self] in
            guard let self else { return }
            try? self.profiles.save(to: self.dataRoot.appendingPathComponent("profiles.json"))
        }
        removeOrphanedProfileFolders()
        // One preference change reaches every open window.
        settings.onChange = { [weak self] key in self?.controllers.forEach { $0.settingChanged(key) } }

        let first = makeController(kind: .standard)
        first.start()
        sync?.vaultProvider = { [weak self] in self?.primary?.vault }
        sync?.start()
        installMenu()
        if let t = env["PANE_DEBUG_THEME"].flatMap(ThemeChoice.init(rawValue:)) { settings.theme = t }
        if env["PANE_DEBUG_AGENT_PRIVATE"] != nil { settings.agentPrivate = true }
        if let n = env["PANE_DEBUG_MEMBER"].flatMap(Int.init) { account.restore(email: "stepan@example.com", lastSync: Date()); account.debugSetMember(MemberInfo(number: n, since: Date(timeIntervalSince1970: 1714521600))) }
        if env["PANE_DEBUG_PRIVATE"] != nil { openPrivateWindow() }
        if let id = env["PANE_DEBUG_PROFILE"], let p = profiles.profile(id) { openProfile(p) }
        let window = (env["PANE_DEBUG_PRIVATE"] != nil || env["PANE_DEBUG_PROFILE"] != nil) ? controllers.last : primary
        if let prefix = env["PANE_SNAPSHOT"] {
            // Debug aid: draw the UI into PNGs, then quit.
            let win = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    if env["PANE_DEBUG_SPLIT"] != nil { Task { @MainActor in try? (await win?.debugSplit() ?? "").write(toFile: prefix + "-split.txt", atomically: true, encoding: .utf8) } }
                    if env["PANE_DEBUG_PW"] != nil { Task { @MainActor in try? (await win?.debugPasswords() ?? "").write(toFile: prefix + "-pw.txt", atomically: true, encoding: .utf8) } }
                    if let n = env["PANE_DEBUG_STRESS_ALL"].flatMap(Int.init) { Task { @MainActor in try? (await win?.debugStressEverything(rounds: n) ?? "").write(toFile: prefix + "-stress.txt", atomically: true, encoding: .utf8) } }
                    if let n = env["PANE_DEBUG_SIDEBAR"].flatMap(Int.init) { Task { @MainActor in try? (await win?.debugSidebarStress(steps: n) ?? "").write(toFile: prefix + "-sidebar.txt", atomically: true, encoding: .utf8) } }
                    if env["PANE_DEBUG_AUTOFILL"] != nil { Task { @MainActor in try? (await win?.debugAutofill() ?? "").write(toFile: prefix + "-autofill.txt", atomically: true, encoding: .utf8) } }
                    if let l = env["PANE_DEBUG_LONG"] { win?.debugLongStrings(Set(l.split(separator: ",").map(String.init))) }
                    if env["PANE_DEBUG_FEATURES"] != nil { Task { @MainActor in try? (await win?.debugFeatures() ?? "").write(toFile: prefix + "-features.txt", atomically: true, encoding: .utf8) } }
                    if let n = env["PANE_DEBUG_QUIT"].flatMap(Int.init) { Task { @MainActor in await win?.debugQuitAfterOpening(n) } }
                    if env["PANE_DEBUG_TRANSLATE"] != nil { Task { @MainActor in try? (await win?.debugTranslate() ?? "").write(toFile: prefix + "-translate.txt", atomically: true, encoding: .utf8) } }
                    if env["PANE_DEBUG_PIP"] != nil { Task { @MainActor in try? (await win?.debugPiP() ?? "").write(toFile: prefix + "-pip.txt", atomically: true, encoding: .utf8) } }
                    if env["PANE_DEBUG_PDF"] != nil { Task { @MainActor in try? (await win?.debugPDF() ?? "").write(toFile: prefix + "-pdf.txt", atomically: true, encoding: .utf8) } }
                    if env["PANE_DEBUG_PROBE"] != nil { Task { @MainActor in try? (await win?.debugProbe() ?? "").write(toFile: prefix + "-probe.txt", atomically: true, encoding: .utf8) } }
                    if env["PANE_DEBUG_FULLSCREEN"] != nil { Task { @MainActor in try? (await win?.debugFullscreen() ?? "").write(toFile: prefix + "-fullscreen.txt", atomically: true, encoding: .utf8) } }
                    if env["PANE_DEBUG_CONTEXT"] != nil { Task { @MainActor in try? (await win?.debugContextMenus() ?? "").write(toFile: prefix + "-context.txt", atomically: true, encoding: .utf8) } }
                    if env["PANE_DEBUG_RIGHTCLICK"] != nil { Task { @MainActor in await win?.debugRightClick() } }
                    if env["PANE_DEBUG_INTERNAL"] != nil { Task { @MainActor in try? (await win?.debugInternalPages() ?? "").write(toFile: prefix + "-internal.txt", atomically: true, encoding: .utf8) } }
                    if env["PANE_DEBUG_SITENOTIF"] != nil { Task { @MainActor in try? (await win?.debugSiteNotifications() ?? "").write(toFile: prefix + "-sitenotif.txt", atomically: true, encoding: .utf8) } }
                    if env["PANE_DEBUG_PEEK"] != nil { win?.debugPeek() }
                    if env["PANE_DEBUG_FOCUS_ADDRESS"] != nil { win?.focusAddressBar() }
                    if env["PANE_DEBUG_HOVER"] != nil { win?.debugHoverToolbar() }
                    if let n = env["PANE_DEBUG_STRESS"].flatMap(Int.init) { win?.debugStressPanel(times: n) }
                    if let q = env["PANE_DEBUG_SUGGEST"] { win?.debugShowSuggestions(query: q) }
                    if let t = env["PANE_DEBUG_AGENT_TASK"] { win?.debugAgent(task: t, autoApprove: env["PANE_DEBUG_AGENT_APPROVE"] != nil) }
                    if let a = env["PANE_DEBUG_ASSISTANT"] { win?.debugAssistant(question: a == "demo" ? "Summarize this page" : nil) }
                }
            }
            if env["PANE_SNAPSHOT_REAL"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + max(2, (env["PANE_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 8) - 1.5)) {
                    MainActor.assumeIsolated { Task { @MainActor in try? (await win?.debugRealSnapshot(to: prefix + "-real.png") ?? "").write(toFile: prefix + "-real.txt", atomically: true, encoding: .utf8) } }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (env["PANE_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 8)) {
                MainActor.assumeIsolated {
                    win?.debugSnapshot("main", to: prefix + "-main.png")
                    if env["PANE_DEBUG_AGENT_TASK"] != nil { Task { @MainActor in try? (await win?.debugPageText() ?? "").write(toFile: prefix + "-page.txt", atomically: true, encoding: .utf8) } }
                    if env["PANE_DEBUG_AGENT_TASK"] != nil { try? (win?.debugAgentTranscript() ?? "").write(toFile: prefix + "-agent.txt", atomically: true, encoding: .utf8) }
                    if env["PANE_DEBUG_LAYOUT"] != nil { try? (win?.debugLayoutInfo() ?? "").write(toFile: prefix + "-layout.txt", atomically: true, encoding: .utf8) }
                    if env["PANE_DEBUG_HIT"] != nil { try? (win?.debugHitTest() ?? "").write(toFile: prefix + "-hit.txt", atomically: true, encoding: .utf8) }
                    if let f = env["PANE_AUDIT_AX"] { try? (win?.debugAudit("main") ?? "").write(toFile: f + "-main.txt", atomically: true, encoding: .utf8) }
                    win?.showSettings(nil)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated {
                        win?.debugSnapshot("settings", to: prefix + "-settings.png")
                        if let f = env["PANE_AUDIT_AX"] { try? (win?.debugAudit("settings") ?? "").write(toFile: f + "-settings.txt", atomically: true, encoding: .utf8) }
                        win?.debugOpenShortcuts()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (env["PANE_DEBUG_AGENT_TASK"] != nil ? 9 : 1.5)) {
                        MainActor.assumeIsolated { win?.debugSnapshot("main", to: prefix + "-shortcuts.png") }
                        exit(0)
                    }
                }
            }
        }
        if ProcessInfo.processInfo.environment["PANE_DEBUG_AUTOUPDATE"] != nil, let u = updater {
            // Debug aid: install an update as soon as one is announced (used to test the update path end to end).
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { if case .available = u.state { u.install() } }
            }
        }
        if let q = ProcessInfo.processInfo.environment["PANE_DEBUG_PALETTE"] { window?.debugShowPalette(query: q == "-" ? "" : q) }
        // PANE_ONSCREEN_TEST: keep a test window where it can be drawn (a window nobody sees never runs the display cycle),
        // but don't take focus.
        if let w = env["PANE_DEBUG_WIDTH"].flatMap(Double.init) { controllers.forEach { $0.window?.setContentSize(NSSize(width: w, height: 760)) } }
        if env["PANE_ONSCREEN_TEST"] != nil { controllers.forEach { $0.window?.setFrameOrigin(NSPoint(x: 80, y: 120)); if env["PANE_ONSCREEN_FRONT"] != nil { $0.window?.orderFrontRegardless() } else { $0.window?.orderBack(nil) } } }
        else if env["PANE_OFFSCREEN"] != nil { controllers.forEach { $0.window?.setFrameOrigin(NSPoint(x: -4000, y: 300)) } } else { NSApp.activate() }
    }

    private func offerCrashReport(_ summary: CrashSummary, to url: URL?) {
        guard let url else { return }
        let alert = NSAlert()
        alert.messageText = tr("Pane closed unexpectedly last time")
        alert.informativeText = tr("Your tabs were restored. Want to send an anonymous report so this can be fixed? It contains only the app version, the system version and the names of the functions where it stopped — no addresses, pages or personal data.")
        alert.addButton(withTitle: tr("Send Report")); alert.addButton(withTitle: tr("Don't Send"))
        let preview = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 110))
        preview.string = summary.text; preview.isEditable = false; preview.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let scroll = NSScrollView(frame: preview.frame); scroll.documentView = preview; scroll.hasVerticalScroller = true; scroll.borderType = .lineBorder
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { _ = await CrashReporter.send(summary, to: url) }
    }

    // Notifications (page watches and sites) show even while Pane is in front; a click goes to the page.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let tab = info["tab"] as? String, url = info["url"] as? String ?? ""
        await MainActor.run { (self.active ?? self.controllers.first)?.openNotification(tabID: tab, url: url) }
    }

    /// Links and files from other apps.
    func application(_ application: NSApplication, open urls: [URL]) {
        (active ?? controllers.first)?.openExternal(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let d = dataRoot, ProcessInfo.processInfo.environment["PANE_DEBUG_NO_CRASHFLAG"] == nil { CrashReporter.markCleanExit(in: d) }
        NSApp.windows.forEach { $0.orderOut(nil) }  // the windows vanish at once; the rest of the shutdown happens unseen
        controllers.forEach { $0.saveNow() }  // debounced saves may still be pending
        engine?.shutdown()
    }

    // MARK: Windows

    /// Builds a browser window of the given kind. Standard and profile windows keep their data on disk;
    /// a private window keeps nothing and works from a snapshot of your bookmarks.
    func makeController(kind: WindowKind) -> BrowserWindowController {
        let isMain = controllers.isEmpty
        let storage: WindowStorage?
        let store: BookmarkStore
        switch kind {
        case .standard: storage = WindowStorage(directory: dataRoot); store = bookmarks
        case .profile(let p): storage = WindowStorage(directory: dataRoot.appendingPathComponent("Profiles/\(p.id)")); store = BookmarkStore()
        case .privateSession:
            storage = nil
            store = BookmarkStore()
            store.replaceRoots(bar: bookmarks.bar, other: bookmarks.other)
        }
        let sleepOverride = env["PANE_SLEEP_SECONDS"].flatMap(TimeInterval.init)
        let c = BrowserWindowController(
            engine: engine!, settings: settings, account: account, profiles: profiles, appActions: appActions, kind: kind, storage: storage,
            importers: allImporters(), search: DefaultSearchProvider(),
            updater: kind.isPrivate || kind.profileInfo != nil ? nil : updater,
            bookmarks: store, syncScheduler: kind.isPrivate || kind.profileInfo != nil ? nil : sync,
            assistant: AssistantSession { [settings, assistantKey, env] in
                if env["PANE_DEBUG_ASSISTANT"] == "demo" { return DemoProvider() }
                if let k = env["PANE_DEBUG_OPENAI_KEY"] { return AssistantProviders.make(provider: "openai", model: "gpt-4o-mini", baseURL: "", apiKey: k) }
                return AssistantProviders.make(provider: settings.assistantProvider, model: settings.assistantModel,
                                               baseURL: settings.assistantBaseURL, apiKey: assistantKey.value)
            },
            assistantKey: assistantKey,
            agentProvider: { [settings, assistantKey, env] in
                // Test aid only: a key handed in through the environment for a live model run; never stored.
                if let k = env["PANE_DEBUG_OPENAI_KEY"] { return AssistantProviders.makeAgent(provider: "openai", model: "gpt-4o-mini", baseURL: "", apiKey: k) }
                if env["PANE_DEBUG_AGENT"] == "demo" { return DemoAgentProvider(pageURL: env["PANE_DEBUG_AGENT_URL"] ?? "http://127.0.0.1:8765/form.html") }
                return AssistantProviders.makeAgent(provider: settings.assistantProvider, model: settings.assistantModel,
                                                    baseURL: settings.assistantBaseURL, apiKey: assistantKey.value)
            },
            sleepOverride: sleepOverride)
        if !isMain { c.settingsRouter = { [weak self] in self?.settingsOwner()?.showSettings(nil) } }
        c.onClosed = { [weak self, weak c] in
            guard let self else { return }
            self.controllers.removeAll { $0 === c }
            // Settings lives in one window; if its owner closed, the next window takes over.
            if !self.controllers.contains(where: { $0.settingsRouter == nil }) { self.controllers.first?.settingsRouter = nil }
        }
        controllers.append(c)
        return c
    }

    private func settingsOwner() -> BrowserWindowController? { controllers.first { $0.settingsRouter == nil } ?? controllers.first }

    lazy var appActions = AppActions(
        openProfile: { [weak self] in self?.openProfile($0) },
        deleteProfile: { [weak self] in self?.deleteProfile($0) },
        openPrivateWindow: { [weak self] in self?.openPrivateWindow() },
        isOpen: { [weak self] p in self?.controllers.contains { $0.kind.profileInfo?.id == p.id } ?? false })

    func openProfile(_ p: ProfileInfo) {
        if let existing = controllers.first(where: { $0.kind.profileInfo?.id == p.id }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        makeController(kind: .profile(p)).start()
        NSApp.activate()
    }

    func openPrivateWindow() {
        makeController(kind: .privateSession).start()
        NSApp.activate()
    }

    func deleteProfile(_ p: ProfileInfo) {
        controllers.first { $0.kind.profileInfo?.id == p.id }?.window?.close()
        profiles.remove(p.id)
        try? FileManager.default.removeItem(at: dataRoot.appendingPathComponent("Profiles/\(p.id)"))
    }

    /// A deleted profile's folder can be busy at that moment; sweep up anything no profile owns at launch.
    private func removeOrphanedProfileFolders() {
        let dir = dataRoot.appendingPathComponent("Profiles")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names where profiles.profile(n) == nil { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
    }

    @objc func newPrivateWindow(_ s: Any?) { openPrivateWindow() }
    @objc func printPage(_ s: Any?) { active?.printPage(s) }
    @objc func savePDF(_ s: Any?) { active?.savePageAsPDF(s) }
    @objc func openProfileFromMenu(_ s: NSMenuItem) {
        if let id = s.representedObject as? String, let p = profiles.profile(id) { openProfile(p) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        do {
            menu.removeAllItems()
            for p in profiles.profiles {
                let it = NSMenuItem(title: p.name, action: #selector(openProfileFromMenu(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = p.id
                it.state = controllers.contains { $0.kind.profileInfo?.id == p.id } ? .on : .off
                menu.addItem(it)
            }
            if profiles.profiles.isEmpty {
                let none = NSMenuItem(title: tr("No other profiles yet"), action: nil, keyEquivalent: ""); none.isEnabled = false
                menu.addItem(none)
            }
            menu.addItem(.separator())
            let manage = NSMenuItem(title: tr("Manage Profiles…"), action: #selector(showSettings(_:)), keyEquivalent: "")
            manage.target = self
            menu.addItem(manage)
        }
    }

    @objc func openLocation(_ sender: Any?) { active?.focusAddressBar() }
    @objc func newTab(_ s: Any?) { active?.newTab(s) }
    @objc func closeTab(_ s: Any?) { active?.closeCurrentTab(s) }
    @objc func newGroup(_ s: Any?) { active?.newGroup(s) }
    @objc func togglePin(_ s: Any?) { active?.togglePinCurrentTab(s) }
    @objc func sleepTab(_ s: Any?) { active?.sleepCurrentTab(s) }
    @objc func nextTab(_ s: Any?) { active?.selectNextTab(s) }
    @objc func prevTab(_ s: Any?) { active?.selectPreviousTab(s) }
    @objc func selectTabNumber(_ s: NSMenuItem) { active?.selectTab(number: s.tag) }
    @objc func reopenClosedTab(_ s: Any?) { active?.reopenClosedTab(s) }
    @objc func copyPageAddress(_ s: Any?) { active?.copyPageAddress(s) }
    @objc func stopAgent(_ s: Any?) { active?.stopAgent(s) }
    @objc func toggleAssistant(_ s: Any?) { active?.toggleAssistant(s) }
    @objc func showFind(_ s: Any?) { active?.showFind(s) }
    @objc func findNext(_ s: Any?) { active?.findNextMatch(s) }
    @objc func findPrevious(_ s: Any?) { active?.findPreviousMatch(s) }
    @objc func showDownloads(_ s: Any?) { active?.toggleDownloads(s) }
    @objc func goBack(_ s: Any?) { active?.navigateBack(s) }
    @objc func goForward(_ s: Any?) { active?.navigateForward(s) }
    @objc func reloadPage(_ s: Any?) { active?.reloadPage(s) }
    @objc func nextWorkspace(_ s: Any?) { active?.nextWorkspace(s) }
    @objc func previousWorkspace(_ s: Any?) { active?.previousWorkspace(s) }
    @objc func toggleReader(_ s: Any?) { active?.toggleReader(s) }
    @objc func openFile(_ s: Any?) { active?.openFile(s) }
    @objc func savePageAs(_ s: Any?) { active?.savePageAs(s) }
    @objc func sharePage(_ s: Any?) { active?.sharePage(s) }
    @objc func toggleFloatingAssistant(_ s: Any?) { active?.toggleFloatingAssistant(s) }
    @objc func showDevTools(_ s: Any?) { active?.showDevTools(s) }
    @objc func viewSource(_ s: Any?) { active?.viewSource(s) }
    @objc func addNote(_ s: Any?) { active?.addNote(s) }
    @objc func togglePictureInPicture(_ s: Any?) { active?.togglePictureInPicture(s) }
    @objc func showHistory(_ s: Any?) { active?.showHistory(s) }
    @objc func translatePage(_ s: Any?) { active?.translatePage(s) }
    @objc func fillSavedLogin(_ s: Any?) { active?.fillSavedLogin(s) }
    @objc func toggleSplit(_ s: Any?) { active?.toggleSplit(s) }
    @objc func summarizePage(_ s: Any?) { active?.summarizePage(s) }
    @objc func zoomIn(_ s: Any?) { active?.zoomIn(s) }
    @objc func zoomOut(_ s: Any?) { active?.zoomOut(s) }
    @objc func zoomReset(_ s: Any?) { active?.zoomReset(s) }
    @objc func toggleSidebar(_ s: Any?) { active?.toggleSidebar() }
    @objc func checkForUpdates(_ s: Any?) { active?.checkForUpdates(s) }
    @objc func showSettings(_ s: Any?) { active?.showSettings(s) }
    @objc func showShortcuts(_ s: Any?) { active?.toggleShortcuts(s) }
    @objc func openPalette(_ s: Any?) { active?.togglePalette(s) }
    @objc func bookmarkPage(_ s: Any?) { active?.bookmarkThisPage(s) }
    @objc func toggleBookmarksBar(_ s: Any?) { active?.toggleBookmarksBar(s) }
    @objc func showAllBookmarks(_ s: Any?) { active?.showAllBookmarks(s) }
    @objc func importBookmarks(_ s: NSMenuItem) { active?.importBookmarks(from: s.tag) }

    private func installMenu() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", target: AnyObject? = nil,
                  mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: tr(title), action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let host = NSMenuItem(); let m = NSMenu(title: tr(title))
            items.forEach(m.addItem); host.submenu = m; main.addItem(host)
        }
        let profileMenuItem = NSMenuItem(title: tr("New Window in Profile"), action: nil, keyEquivalent: "")
        let profileSub = NSMenu(title: tr("New Window in Profile"))
        profileSub.delegate = self
        profileMenuItem.submenu = profileSub
        submenu("Pane", [
            item("About Pane", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("Check for Updates…", #selector(checkForUpdates(_:)), target: self),
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ",", target: self),
            item("Keyboard Shortcuts", #selector(showShortcuts(_:)), "/", target: self),
            .separator(),
            item("Hide Pane", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit Pane", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("New Tab", #selector(newTab(_:)), "t", target: self),
            item("New Group…", #selector(newGroup(_:)), "n", target: self, mods: [.command, .option]),
            item("New Private Window", #selector(newPrivateWindow(_:)), "n", target: self, mods: [.command, .shift]),
            profileMenuItem,
            item("Search Tabs, Bookmarks and History…", #selector(openPalette(_:)), "k", target: self),
            item("Open Location…", #selector(openLocation(_:)), "l", target: self),
            item("Fill Saved Login", #selector(fillSavedLogin(_:)), "l", target: self, mods: [.command, .option]),
            item("Copy Page Address", #selector(copyPageAddress(_:)), "c", target: self, mods: [.command, .shift]),
            .separator(),
            item("Close Tab", #selector(closeTab(_:)), "w", target: self),
            item("Reopen Closed Tab", #selector(reopenClosedTab(_:)), "t", target: self, mods: [.command, .shift]),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", mods: [.command, .shift]),
            .separator(),
            item("Open File…", #selector(openFile(_:)), "o", target: self),
            item("Save Page As…", #selector(savePageAs(_:)), "s", target: self),
            item("Share Page…", #selector(sharePage(_:)), "", target: self),
            .separator(),
            item("Print…", #selector(printPage(_:)), "p", target: self),
            item("Save Page as PDF…", #selector(savePDF(_:)), "", target: self),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z", mods: [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find in Page…", #selector(showFind(_:)), "f", target: self),
            item("Find Next", #selector(findNext(_:)), "g", target: self),
            item("Find Previous", #selector(findPrevious(_:)), "g", target: self, mods: [.command, .shift]),
        ])
        submenu("View", [
            item("Toggle Sidebar", #selector(toggleSidebar(_:)), "s", target: self, mods: [.command, .control]),
            item("Ask the Assistant", #selector(toggleAssistant(_:)), "a", target: self, mods: [.command, .shift]),
            item("Floating Assistant Window", #selector(toggleFloatingAssistant(_:)), "a", target: self, mods: [.command, .option, .shift]),
            item("Stop the Agent", #selector(stopAgent(_:)), ".", target: self),
            .separator(),
            item("Reload Page", #selector(reloadPage(_:)), "r", target: self),
            item("Split View", #selector(toggleSplit(_:)), "\\", target: self, mods: [.command, .option]),
            item("Translate Page", #selector(translatePage(_:)), "t", target: self, mods: [.command, .option]),
            item("Picture in Picture", #selector(togglePictureInPicture(_:)), "p", target: self, mods: [.command, .option]),
            item("Note for This Page…", #selector(addNote(_:)), "n", target: self, mods: [.command, .option, .control]),
            item("Developer Tools", #selector(showDevTools(_:)), "i", target: self, mods: [.command, .option]),
            item("View Source", #selector(viewSource(_:)), "u", target: self, mods: [.command, .option]),
            item("Reader Mode", #selector(toggleReader(_:)), "r", target: self, mods: [.command, .option]),
            item("Summarize Page", #selector(summarizePage(_:)), "s", target: self, mods: [.command, .option]),
            item("Back", #selector(goBack(_:)), "[", target: self),
            item("Forward", #selector(goForward(_:)), "]", target: self),
            .separator(),
            item("Zoom In", #selector(zoomIn(_:)), "+", target: self),
            item("Zoom Out", #selector(zoomOut(_:)), "-", target: self),
            item("Actual Size", #selector(zoomReset(_:)), "0", target: self),
            .separator(),
            item("Show Downloads", #selector(showDownloads(_:)), "j", target: self, mods: [.command, .shift]),
        ])
        let importMenu = NSMenuItem(title: tr("Import Bookmarks"), action: nil, keyEquivalent: "")
        let importSub = NSMenu()
        for (i, name) in (primary?.importerNames ?? []).enumerated() {
            let it = NSMenuItem(title: String(localized: "From \(name)…"), action: #selector(importBookmarks(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; importSub.addItem(it)
        }
        importMenu.submenu = importSub
        submenu("Bookmarks", [
            item("Bookmark This Page", #selector(bookmarkPage(_:)), "d", target: self),
            item("Show Bookmarks Bar", #selector(toggleBookmarksBar(_:)), "b", target: self, mods: [.command, .shift]),
            item("Show All Bookmarks", #selector(showAllBookmarks(_:)), "b", target: self, mods: [.command, .option]),
            .separator(),
            importMenu,
        ])
        submenu("History", [
            item("Show All History", #selector(showHistory(_:)), "y", target: self),
        ])
        submenu("Tab", [
            item("Pin / Unpin Tab", #selector(togglePin(_:)), "p", target: self, mods: [.command, .shift]),
            item("Put Tab to Sleep", #selector(sleepTab(_:)), "z", target: self, mods: [.command, .option]),
            .separator(),
            item("Next Workspace", #selector(nextWorkspace(_:)), "]", target: self, mods: [.command, .option]),
            item("Previous Workspace", #selector(previousWorkspace(_:)), "[", target: self, mods: [.command, .option]),
            .separator(),
            item("Next Tab", #selector(nextTab(_:)), "]", target: self, mods: [.command, .shift]),
            item("Next Tab (⌃Tab)", #selector(nextTab(_:)), "\t", target: self, mods: [.control]),
            item("Previous Tab (⌃⇧Tab)", #selector(prevTab(_:)), "\t", target: self, mods: [.control, .shift]),
            item("Previous Tab", #selector(prevTab(_:)), "[", target: self, mods: [.command, .shift]),
            .separator(),
        ] + (1...9).map { n in
            let i = item(n == 9 ? "Last Tab" : tr("Tab") + " \(n)", #selector(selectTabNumber(_:)), "\(n)", target: self)
            i.tag = n
            return i
        })
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.mainMenu = main
    }
}

MainActor.assumeIsolated {
    // A stray layout exception should be logged, not take the whole browser (and every open tab) down with it.
    UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": false])
    let app = PCApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(ProcessInfo.processInfo.environment["PANE_OFFSCREEN"] != nil ? .accessory : .regular)
    // Debug aid: PANE_APPEARANCE=light|dark forces a theme.
    switch ProcessInfo.processInfo.environment["PANE_APPEARANCE"] {
    case "light": app.appearance = NSAppearance(named: .aqua)
    case "dark": app.appearance = NSAppearance(named: .darkAqua)
    default: break
    }
    withExtendedLifetime(delegate) { app.run() }
}

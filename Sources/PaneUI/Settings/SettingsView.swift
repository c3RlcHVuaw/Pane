import PaneModel
import SwiftUI

/// Update state mirrored for SwiftUI (the browser window owns the updater and feeds this).
@MainActor
public final class UpdateStatus: ObservableObject {
    @Published public var state: UpdateState = .idle
    public init() {}
}

struct SettingsActions {
    var checkForUpdates: () -> Void
    var installUpdate: () -> Void
    var clearHistory: () -> Void
    var historyCount: () -> Int
    var hasAssistantKey: () -> Bool
    var saveAssistantKey: (String) -> Void
    var clearAssistantKey: () -> Void
    var testAssistant: () async -> (ok: Bool, text: String)
    var vault: PasswordVault
    var clearBrowsingData: () async -> Void
    var isDefaultBrowser: () -> Bool
    var makeDefaultBrowser: () -> Void
    var releaseHistory: () async -> [ReleaseEntry]
    var openPage: (String) -> Void
    var showHistory: () -> Void
    var notificationDecisions: () -> [String: String]
    var setNotificationDecision: (String, String?) -> Void
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, search, appearance, assistant, profiles, account, shortcuts, privacy, autofill, updates, extensions, icon, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .search: "Search"
        case .appearance: "Appearance"
        case .assistant: "Assistant"
        case .profiles: "Profiles"
        case .account: "Account & Sync"
        case .shortcuts: "Shortcuts"
        case .privacy: "Privacy"
        case .updates: "Updates"
        case .autofill: "AutoFill"
        case .extensions: "Extensions"
        case .icon: "Icon"
        case .advanced: "Advanced"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .search: "magnifyingglass"
        case .appearance: "paintbrush.fill"
        case .assistant: "sparkles"
        case .profiles: "person.2.fill"
        case .account: "person.crop.circle.fill"
        case .shortcuts: "keyboard.fill"
        case .privacy: "hand.raised.fill"
        case .updates: "arrow.down.circle.fill"
        case .autofill: "person.text.rectangle.fill"
        case .extensions: "puzzlepiece.extension.fill"
        case .icon: "app.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .search: .blue
        case .appearance: .purple
        case .assistant: .indigo
        case .profiles: .pink
        case .account: .teal
        case .shortcuts: .orange
        case .privacy: .red
        case .updates: .green
        case .autofill: .cyan
        case .extensions: .mint
        case .icon: .orange
        case .advanced: .gray
        }
    }
}

struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 24
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

/// Settings sidebar rows: a small icon with a little air around it.
struct SettingsLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) { configuration.icon; configuration.title }
    }
}

struct SettingsRoot: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var account: AccountSession
    @ObservedObject var updates: UpdateStatus
    let profiles: ProfilesStore
    let app: AppActions
    let actions: SettingsActions
    @State private var selection: SettingsPane = SettingsPane(rawValue: ProcessInfo.processInfo.environment["PANE_DEBUG_SETTINGS_PANE"] ?? "") ?? .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label { Text(LocalizedStringKey(pane.title)).font(.system(size: 13)) } icon: { IconBadge(symbol: pane.symbol, tint: pane.tint, size: 20) }
                    .labelStyle(SettingsLabelStyle())
                    .tag(pane)
                    .padding(.vertical, 3)
                    .padding(.leading, 6)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 230)
        } detail: {
            Group {
                switch selection {
                case .general: GeneralPane(settings: settings, actions: actions)
                case .search: SearchPane(settings: settings)
                case .appearance: AppearancePane(settings: settings)
                case .assistant: AssistantPane(settings: settings, actions: actions)
                case .profiles: ProfilesPane(profiles: profiles, app: app)
                case .account: AccountPane(account: account)
                case .shortcuts: ShortcutsPane()
                case .privacy: PrivacyPane(settings: settings, actions: actions, vault: actions.vault)
                case .updates: UpdatesPane(settings: settings, updates: updates, actions: actions)
                case .autofill: AutofillPane()
                case .extensions: ExtensionsPane()
                case .icon: IconPane(settings: settings)
                case .advanced: AdvancedPane(settings: settings, actions: actions)
                }
            }
            .navigationTitle(Text(LocalizedStringKey(selection.title)))
        }
        .frame(width: 800, height: 560)
        .tint(settings.theme.color)
    }
}

// MARK: General

struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions
    @State private var isDefault = false
    @State private var language = AppLanguage.chosen
    private let sleepChoices: [(String, Int)] = [("Never", 0), ("After 10 minutes", 10), ("After 30 minutes", 30), ("After 1 hour", 60), ("After 3 hours", 180)]

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .accessibilityLabel("Language")
                .onChange(of: language) { _, new in AppLanguage.choose(new) }
                if language != AppLanguage.chosenAtLaunch {
                    HStack {
                        Text("Restart Pane to change the language.").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { Relauncher.relaunch() }
                    }
                }
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default browser")
                        Text(isDefault ? "Pane opens the links you click in other apps." : "Links you click in Mail, Messages and other apps open in another browser.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isDefault { Label("Pane is the default", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout) }
                    else { Button("Make Default") { actions.makeDefaultBrowser(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isDefault = actions.isDefaultBrowser() } } }
                }
            }
            Section {
                Toggle("Swipe between pages with the trackpad", isOn: $settings.swipeNavigation)
            } footer: { Text("Needs “Swipe between pages” turned on in System Settings ▸ Trackpad ▸ More Gestures.") }
            Section("Startup") {
                Picker("When Pane opens", selection: $settings.startup) {
                    ForEach(StartupBehavior.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityLabel("When Pane opens")
                Picker("New tabs open", selection: $settings.newTabPage) {
                    ForEach(NewTabPage.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityLabel("New tabs open")
                if settings.newTabPage == .custom {
                    TextField("Address", text: $settings.customNewTabURL, prompt: Text("example.com"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Custom new tab address")
                }
            }
            Section {
                Picker("Put inactive tabs to sleep", selection: $settings.sleepMinutes) {
                    ForEach(sleepChoices, id: \.1) { Text(LocalizedStringKey($0.0)).tag($0.1) }
                }
                .accessibilityLabel("Put inactive tabs to sleep")
            } header: { Text("Tabs") } footer: {
                Text("Sleeping tabs free memory and wake the moment you open them. Pinned tabs and tabs playing audio never sleep.")
            }
            Section("Bookmarks") {
                Toggle("Show bookmarks bar", isOn: $settings.showBookmarksBar)
            }
        }
        .formStyle(.grouped)
        .onAppear { isDefault = actions.isDefaultBrowser() }
    }
}

// MARK: Search

struct SearchPane: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        Form {
            Section {
                ForEach(SearchEngine.all) { engine in
                    Button { withAnimation(.snappy(duration: 0.2)) { settings.searchEngineID = engine.id } } label: {
                        HStack(spacing: 12) {
                            Text(String(engine.name.prefix(1)))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(color(for: engine.id).gradient, in: Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(engine.name).foregroundStyle(.primary)
                                Text(URL(string: engine.home)?.host ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if engine.id == settings.searchEngineID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).transition(.scale.combined(with: .opacity))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(engine.id == settings.searchEngineID ? .isSelected : [])
                }
            } header: { Text("Default search engine") } footer: {
                Text("Used by the address bar and ⌘K when what you type isn't a web address.")
            }
            Section("Example") {
                Text(settings.searchEngine.url(for: "pane browser"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
    private func color(for id: String) -> Color {
        ["google": .blue, "duckduckgo": .orange, "yandex": .red, "bing": .teal, "brave": .orange, "startpage": .indigo, "ecosia": .green][id] ?? .gray
    }
}

// MARK: Appearance

struct AppearancePane: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        AppearanceCard(choice: choice, selected: settings.appearance == choice) {
                            withAnimation(.snappy(duration: 0.2)) { settings.appearance = choice }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } header: { Text("Theme") } footer: {
                Text("Pane's glass adapts to light and dark. System follows your Mac, including Reduce Transparency and Increase Contrast.")
            }
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(ThemeChoice.allCases) { t in
                            ThemeSwatch(theme: t, selected: settings.theme == t) { withAnimation(.snappy(duration: 0.25)) { settings.theme = t } }
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 2)
                }
            } header: { Text("Colour theme") } footer: {
                Text("Colours the window glass, the sidebar, the start page and buttons.")
            }
            Section {
                Toggle("Tint the sidebar with the site's colour", isOn: $settings.sidebarTint)
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceCard: View {
    let choice: AppearanceChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(width: 150, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1))
                Text(choice.title).font(.callout.weight(selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.title) appearance")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        switch choice {
        case .light: mini(dark: false)
        case .dark: mini(dark: true)
        case .system:
            HStack(spacing: 0) {
                mini(dark: false).frame(width: 75).clipped()
                mini(dark: true).frame(width: 75).clipped().offset(x: -0)
            }
            .overlay(alignment: .center) { Rectangle().fill(.clear) }
            .mask { Rectangle() }
            .background(mini(dark: true))
        }
    }

    private func mini(dark: Bool) -> some View {
        let bg = dark ? Color(red: 0.13, green: 0.13, blue: 0.17) : Color(red: 0.93, green: 0.93, blue: 0.97)
        let panel = dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
        let page = dark ? Color(red: 0.18, green: 0.18, blue: 0.22) : Color.white
        return ZStack(alignment: .topLeading) {
            bg
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(panel).frame(width: 40, height: 80).offset(x: 6, y: 8)
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(page).frame(width: 90, height: 62).offset(x: 52, y: 26)
            Capsule().fill(panel).frame(width: 70, height: 10).offset(x: 56, y: 8)
            Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: 12, y: 16)
        }
    }
}

// MARK: Shortcuts

struct KeyCaps: View {
    let keys: String
    private var tokens: [String] {
        var out: [String] = [], rest = ""
        for ch in keys {
            if "⌘⇧⌥⌃".contains(ch) {
                if !rest.isEmpty { out.append(rest); rest = "" }
                out.append(String(ch))
            } else { rest.append(ch) }
        }
        if !rest.isEmpty { out.append(rest) }
        return out
    }
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, t in
                Text(t)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20)
                    .padding(.horizontal, t.count > 1 ? 5 : 2)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys)
    }
}

struct ShortcutsPane: View {
    var body: some View {
        Form {
            ForEach(ShortcutCatalog.sections) { section in
                Section {
                    ForEach(section.items) { item in
                        HStack { Text(verbatim: tr(item.name)); Spacer(); KeyCaps(keys: item.keys) }
                    }
                } header: {
                    Label(tr(section.title), systemImage: section.symbol)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Privacy

struct PrivacyPane: View {
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions
    @ObservedObject var vault: PasswordVault
    @State private var confirm = false
    @State private var count = 0
    @State private var confirmClearData = false
    @State private var sites: [String: String] = [:]
    @State private var clearingData = false
    @State private var clearedData = false
    var body: some View {
        Form {
            Section {
                Toggle("Show search suggestions in the address bar", isOn: $settings.webSuggestions)
                Toggle("Block ads and trackers", isOn: $settings.blockAds)
                Toggle("Remember a short snippet of each page for search", isOn: $settings.rememberPageText)
            } header: { Text("Content") } footer: {
                Text("Pane refuses requests to well-known ad and tracking servers. Pages load faster and follow you less. If a site misbehaves, turn this off and reload. With suggestions on, what you type in the address bar goes to your search engine as you type. The snippets let ⌘K and the assistant find a page by what it says; they stay on this Mac and are cleared with your history.")
            }
            Section {
                if sites.isEmpty { Text("No site can show notifications yet.").foregroundStyle(.secondary) }
                ForEach(sites.keys.sorted(), id: \.self) { origin in
                    HStack {
                        Image(systemName: sites[origin] == "granted" ? "bell.fill" : "bell.slash").foregroundStyle(sites[origin] == "granted" ? .green : .secondary).frame(width: 22)
                        Text(verbatim: URL(string: origin)?.host ?? origin)
                        Spacer()
                        Text(sites[origin] == "granted" ? "Allowed" : "Blocked").font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) { actions.setNotificationDecision(origin, nil); sites[origin] = nil } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
                    }
                }
            } header: { Text("Site notifications") } footer: { Text("Pages that are open in Pane can show notifications in the macOS notification centre once you allow them.") }
            .onAppear { sites = actions.notificationDecisions() }
            Section {
                Toggle("Offer to save passwords", isOn: $settings.offerToSavePasswords)
                ForEach(vault.logins.sorted { $0.host < $1.host }) { l in
                    HStack {
                        Image(systemName: "key.fill").foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: l.host)
                            if !l.user.isEmpty { Text(verbatim: l.user).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(role: .destructive) { vault.remove(l.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete").accessibilityLabel("Delete")
                    }
                }
            } header: { Text("Passwords") } footer: {
                Text("Passwords are kept in your Mac's Keychain, never synced or sent anywhere, and filled in only when you choose Fill (⌥⌘L) on the site they belong to.")
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cookies and cached files")
                        Text(clearedData ? "Cleared. Sites will ask you to sign in again." : "Signs you out of most sites and frees disk space.").font(.caption).foregroundStyle(clearedData ? .green : .secondary)
                    }
                    Spacer()
                    Button("Clear…", role: .destructive) { confirmClearData = true }.disabled(clearingData)
                }
            } header: { Text("Browsing data") }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Browsing history")
                        Text("\(count) pages remembered on this Mac").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear…", role: .destructive) { confirm = true }.disabled(count == 0)
                }
            } header: { Text("History") } footer: {
                Text("History powers search in ⌘K. It stays on this Mac and is never uploaded, even with sync on.")
            }
        }
        .formStyle(.grouped)
        .onAppear { count = actions.historyCount() }
        .confirmationDialog("Clear cookies and cached files?", isPresented: $confirmClearData, titleVisibility: .visible) {
            Button("Clear Cookies and Cache", role: .destructive) {
                clearingData = true
                Task { await actions.clearBrowsingData(); clearingData = false; clearedData = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You will be signed out of most sites.") }
        .confirmationDialog("Clear all browsing history?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { actions.clearHistory(); count = actions.historyCount() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This can't be undone.") }
    }
}

// MARK: Updates

struct UpdatesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updates: UpdateStatus
    let actions: SettingsActions

    private var version: String {
        let i = Bundle.main.infoDictionary ?? [:]
        let v = i["CFBundleShortVersionString"] as? String ?? "?", b = i["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(v) (\(b))")
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pane").font(.title2.weight(.semibold))
                        Text(version).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            Section("Updates") {
                statusRow
                Toggle("Check for updates automatically", isOn: $settings.automaticUpdates)
            }
            Section {
                if history.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Loading the list of versions…").foregroundStyle(.secondary) }
                } else {
                    ForEach(Array(history.enumerated()), id: \.element.id) { i, r in
                        DisclosureGroup(isExpanded: Binding(get: { open.contains(r.id) || (i == 0 && !closedFirst) }, set: { on in
                            if on { open.insert(r.id) } else { open.remove(r.id); if i == 0 { closedFirst = true } }
                        })) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(r.points.enumerated()), id: \.offset) { _, p in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Circle().fill(Color.accentColor).frame(width: 4, height: 4).offset(y: -2)
                                        Text(verbatim: p).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            HStack {
                                Text(verbatim: "\(r.version) (\(r.build))").font(.system(size: 13, weight: .semibold))
                                if r.build == currentBuild { Text("Installed").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.green.opacity(0.18))).foregroundStyle(.green) }
                                Spacer()
                                Text(verbatim: r.date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: { Text("What changed in each version") }
        }
        .formStyle(.grouped)
        .task { history = await actions.releaseHistory() }
    }

    @State private var history: [ReleaseEntry] = []
    @State private var open: Set<Int> = []
    @State private var closedFirst = false
    private var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    @ViewBuilder private var statusRow: some View {
        switch updates.state {
        case .idle:
            HStack { Label("Pane is up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green); Spacer()
                Button("Check Now") { actions.checkForUpdates() } }
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary); Spacer() }
        case .available(let info):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Version \(info.version) (\(info.build)) is available", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    Spacer()
                    Button("Update Now") { actions.installUpdate() }.buttonStyle(.borderedProminent)
                }
                if !info.notes.isEmpty { Text(info.notes).font(.callout).foregroundStyle(.secondary) }
            }
        case .downloading(let p):
            HStack(spacing: 10) {
                if p >= 0 { ProgressView(value: p).frame(maxWidth: 220) } else { ProgressView().controlSize(.small) }
                Text(p >= 0 ? String(localized: "Downloading… \(Int(p * 100))%") : tr("Downloading…")).foregroundStyle(.secondary)
                Spacer()
            }
        case .installing:
            HStack { ProgressView().controlSize(.small); Text("Restarting to finish the update…").foregroundStyle(.secondary); Spacer() }
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("Try Again") { actions.checkForUpdates() }
            }
        }
    }
}


/// Starts a fresh copy of the app and quits this one (used after changing the language).
enum Relauncher {
    @MainActor static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"$1\"", "sh", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}


private struct ThemeSwatch: View {
    let theme: ThemeChoice
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(theme == .system
                        ? AnyShapeStyle(AngularGradient(colors: [.blue, .purple, .pink, .orange, .green, .blue], center: .center))
                        : AnyShapeStyle(LinearGradient(colors: [theme.color.opacity(0.95), theme.color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .frame(width: 38, height: 38)
                        .shadow(color: theme.color.opacity(hover || selected ? 0.55 : 0.25), radius: hover ? 9 : 4, y: 2)
                    if selected { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white).transition(.scale.combined(with: .opacity)) }
                }
                .scaleEffect(hover ? 1.08 : 1)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.5 : 0), lineWidth: 2).frame(width: 46, height: 46))
                Text(verbatim: theme.title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
        .accessibilityLabel(Text(verbatim: theme.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}


// MARK: Advanced

/// Chromium's own diagnostic pages, and a shortcut to the full history.
struct AdvancedPane: View {
    @ObservedObject var settings: AppSettings
    let actions: SettingsActions

    private let pages: [(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey, url: String)] = [
        ("info.circle", "About this engine", "Chromium version and how it was built", "chrome://version"),
        ("cpu", "Graphics", "What the graphics card is doing", "chrome://gpu"),
        ("network", "Network", "Connections, DNS, proxies and a request log", "chrome://net-internals"),
        ("video", "Calls and cameras", "WebRTC connections and their statistics", "chrome://webrtc-internals"),
        ("play.rectangle", "Media players", "Audio and video playing right now", "chrome://media-internals"),
        ("gearshape.2", "Service workers", "Background scripts of the sites you visit", "chrome://serviceworker-internals"),
        ("square.stack.3d.up", "Processes", "Which page runs in which process", "chrome://process-internals"),
        ("chart.bar", "Histograms", "Counters the engine keeps about itself", "chrome://histograms"),
        ("desktopcomputer", "System", "Details about this Mac as the engine sees it", "chrome://system"),
        ("doc.text", "Licences", "Open-source software inside Pane", "chrome://credits"),
        ("list.bullet", "All internal pages", "Everything the engine can show", "chrome://chrome-urls"),
    ]

    var body: some View {
        Form {
            Section {
                BadgeToggle(symbol: "hand.tap.fill", color: .blue, title: "Haptic feedback when reordering tabs", isOn: $settings.hapticFeedback)
                BadgeToggle(symbol: "arrow.left.arrow.right", color: .green, title: "Swipe between pages with the trackpad", isOn: $settings.swipeNavigation)
            }
            Section {
                BadgeToggle(symbol: "macwindow.on.rectangle", color: .green, title: "Restore windows from the previous session",
                            isOn: Binding(get: { settings.startup == .restore }, set: { settings.startup = $0 ? .restore : .newTab }))
                BadgeToggle(symbol: "text.magnifyingglass", color: .red, title: "Remember page text for search", subtitle: "Stays on this Mac.", isOn: $settings.rememberPageText)
                BadgeToggle(symbol: "paintpalette.fill", color: .purple, title: "Tint the sidebar with the page colour", isOn: $settings.sidebarTint)
                BadgeToggle(symbol: "shield.lefthalf.filled", color: .orange, title: "Block ads and trackers", isOn: $settings.blockAds)
            }
            Section {
                Button { actions.showHistory() } label: {
                    HStack { Label("Browsing history", systemImage: "clock.arrow.circlepath"); Spacer(); Text("⌘Y").foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: { Text("History") } footer: {
                Text("Search everything you have visited, delete single pages or clear all of it.")
            }
            Section {
                ForEach(pages, id: \.url) { p in
                    Button { actions.openPage(p.url) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: p.symbol).frame(width: 22).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.title)
                                Text(p.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(verbatim: p.url.replacingOccurrences(of: "chrome://", with: "")).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text("Chromium internal pages") } footer: {
                Text("These open in a new tab. They are for diagnosing problems; changing anything here is at your own risk. Chromium's own settings screens aren't part of Pane — everything you can change lives in these Settings.")
            }
        }
        .formStyle(.grouped)
    }
}


/// A switch row with a coloured icon badge, like the System Settings look.
struct BadgeToggle: View {
    let symbol: String
    let color: Color
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .toggleStyle(.switch)
    }
}

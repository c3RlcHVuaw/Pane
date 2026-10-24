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
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, search, appearance, assistant, profiles, account, shortcuts, privacy, updates
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
                Label { Text(LocalizedStringKey(pane.title)) } icon: { IconBadge(symbol: pane.symbol, tint: pane.tint) }
                    .tag(pane)
                    .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 230)
        } detail: {
            Group {
                switch selection {
                case .general: GeneralPane(settings: settings)
                case .search: SearchPane(settings: settings)
                case .appearance: AppearancePane(settings: settings)
                case .assistant: AssistantPane(settings: settings, actions: actions)
                case .profiles: ProfilesPane(profiles: profiles, app: app)
                case .account: AccountPane(account: account)
                case .shortcuts: ShortcutsPane()
                case .privacy: PrivacyPane(settings: settings, actions: actions, vault: actions.vault)
                case .updates: UpdatesPane(settings: settings, updates: updates, actions: actions)
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
    var body: some View {
        Form {
            Section {
                Toggle("Block ads and trackers", isOn: $settings.blockAds)
                Toggle("Remember a short snippet of each page for search", isOn: $settings.rememberPageText)
            } header: { Text("Content") } footer: {
                Text("Pane refuses requests to well-known ad and tracking servers. Pages load faster and follow you less. If a site misbehaves, turn this off and reload. The snippets let ⌘K and the assistant find a page by what it says; they stay on this Mac and are cleared with your history.")
            }
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
        return "Version \(i["CFBundleShortVersionString"] as? String ?? "?") (\(i["CFBundleVersion"] as? String ?? "?"))"
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
        }
        .formStyle(.grouped)
    }

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

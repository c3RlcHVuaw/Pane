import AppKit
import PaneModel
import SwiftUI

@MainActor
final class AssistantPanelModel: ObservableObject {
    struct TabChoice: Identifiable, Equatable { let id: UUID; let title: String }

    enum Mode: String { case ask, act }
    let session: AssistantSession
    let agent: AgentSession
    @Published var mode: Mode = .act
    @Published var agentEnabled = false
    @Published var includeCurrent = true
    @Published var currentTitle = ""
    @Published var canShareCurrent = false
    @Published var extraTabs: [TabChoice] = []
    @Published var available: [TabChoice] = []
    @Published var configured = false
    @Published var draft = ""
    @Published var accent: Color = .accentColor
    /// Mirrors the "ask before important actions" setting, inverted: on means the agent doesn't ask.
    @Published var autoApprove = false { didSet { if autoApprove != oldValue { onAutoApproveChanged(autoApprove) } } }
    var onAutoApproveChanged: (Bool) -> Void = { _ in }
    @Published var agentPrivate = false { didSet { if agentPrivate != oldValue { onAgentPrivateChanged(agentPrivate) } } }
    var onAgentPrivateChanged: (Bool) -> Void = { _ in }
    @Published var focusToken = 0
    var macros = MacroStore(directory: nil)
    var onSaveMacro: (String) -> Void = { _ in }
    var history = AgentHistoryStore(directory: nil)
    var onRestore: (AgentRunRecord) -> Void = { _ in }
    var onSend: (String) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onClose: () -> Void = {}

    init(session: AssistantSession, agent: AgentSession) { self.session = session; self.agent = agent }

    func toggleExtra(_ t: TabChoice) {
        if let i = extraTabs.firstIndex(of: t) { extraTabs.remove(at: i) } else { extraTabs.append(t) }
    }
}

struct AssistantPanelView: View {
    @ObservedObject var model: AssistantPanelModel
    @ObservedObject var session: AssistantSession
    @ObservedObject var agent: AgentSession
    @FocusState private var composerFocused: Bool
    @State private var showHistory = false
    @StateObject private var voice = VoiceInput()
    private var isAct: Bool { model.mode == .act }
    private var busy: Bool { isAct ? agent.isRunning : session.isStreaming }

    private let suggestions: [(String, String)] = [
        ("doc.text.magnifyingglass", "Summarize this page"),
        ("list.bullet", "What are the key points?"),
        ("tag", "Find prices or numbers on this page"),
        ("arrow.left.arrow.right", "Compare the tabs I've added"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if !model.configured { onboarding }
            else {
                if isAct { AgentTimeline(agent: agent, macros: model.macros, onSuggest: { model.onSend($0) }, onSaveMacro: { model.onSaveMacro($0) }, onAlwaysAllow: { model.autoApprove = true }) } else { contextBar; messages }
                composer
            }
        }
        .onChange(of: model.focusToken) { _, _ in composerFocused = true }
        .tint(model.accent)
    }

    // MARK: Header

    private func modeButton(_ title: LocalizedStringKey, _ mode: AssistantPanelModel.Mode) -> some View {
        let on = model.mode == mode
        return Button { withAnimation(.snappy) { model.mode = mode } } label: {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background { if on { Capsule().fill(model.accent) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var header: some View {
        // Wide panels show the title; narrow ones drop it instead of squeezing the controls out of place.
        ViewThatFits(in: .horizontal) {
            headerRow(showTitle: true)
            headerRow(showTitle: false)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func headerRow(showTitle: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.purple, .blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
            if showTitle { Text("Assistant").font(.system(size: 15, weight: .semibold)).lineLimit(1).fixedSize() }
            if model.agentEnabled {
                HStack(spacing: 2) {
                    modeButton("Ask", .ask)
                    modeButton("Act", .act)
                }
                .padding(2)
                .background { Capsule().fill(Color.primary.opacity(0.10)) }
                .fixedSize()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Assistant mode")
                .help("Ask: answers questions about pages.  Act: controls the browser for you.")
            }
            Spacer(minLength: 4)
            if isAct {
                headerButton(symbol: model.autoApprove ? "checkmark.shield.fill" : "checkmark.shield", tint: model.autoApprove ? .orange : nil,
                             help: model.autoApprove ? "Auto-approve is on: the agent doesn't ask before acting (it still never types passwords). Click to turn off." : "Auto-approve is off: the agent asks before closing tabs, deleting, changing settings or submitting forms. Click to turn on.",
                             label: model.autoApprove ? "Auto-approve on" : "Auto-approve off") { withAnimation(.snappy) { model.autoApprove.toggle() } }
                    .symbolEffect(.bounce, value: model.autoApprove)
                headerButton(symbol: model.agentPrivate ? "lock.shield.fill" : "lock.shield", tint: model.agentPrivate ? .purple : nil,
                             help: model.agentPrivate ? "Private mode is on: the agent works in a private tab and can't see your bookmarks, history or logins. Click to turn off." : "Private mode is off. Turn on to make the agent work in a private tab that can't see your bookmarks, history or logins.",
                             label: model.agentPrivate ? "Private mode on" : "Private mode off") { model.agentPrivate.toggle() }
                headerButton(symbol: "clock.arrow.circlepath", tint: showHistory ? .accentColor : nil, help: "Past conversations", label: "Past conversations") { showHistory.toggle() }
                    .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                        AgentHistoryList(history: model.history, onPick: { run in showHistory = false; model.onRestore(run) })
                    }
            }
            if isAct ? !agent.items.isEmpty : !session.messages.isEmpty {
                headerButton(symbol: "square.and.pencil", tint: nil, help: "New chat", label: "New chat") { withAnimation(.snappy) { if isAct { agent.clear() } else { session.clear() } } }
            }
            headerButton(symbol: "xmark", tint: nil, help: "Close  ⇧⌘A", label: "Close assistant") { model.onClose() }
        }
    }

    private func headerButton(symbol: String, tint: Color?, help: LocalizedStringKey, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? Color.primary.opacity(0.6))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    // MARK: Setup

    private var onboarding: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "key.horizontal.fill").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Connect a model").font(.title3.weight(.semibold))
            Text("Add an API key and the assistant can read the page you're on and answer questions about it. Your key stays in the macOS Keychain.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            Button("Open Assistant Settings") { model.onOpenSettings() }.buttonStyle(.borderedProminent).controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Context chips

    private var contextBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Chip(title: model.currentTitle.isEmpty ? "This page" : model.currentTitle, symbol: model.includeCurrent && model.canShareCurrent ? "checkmark.circle.fill" : "circle",
                     active: model.includeCurrent && model.canShareCurrent, dimmed: !model.canShareCurrent) { model.includeCurrent.toggle() }
                    .help(model.canShareCurrent ? "Share this page with the assistant" : "There's no page to share here")
                ForEach(model.extraTabs) { t in
                    Chip(title: t.title, symbol: "xmark.circle.fill", active: true, dimmed: false) { withAnimation(.snappy) { model.toggleExtra(t) } }
                }
                Menu {
                    if model.available.isEmpty { Text("No other tabs are open") }
                    ForEach(model.available) { t in
                        Button { withAnimation(.snappy) { model.toggleExtra(t) } } label: {
                            Label(t.title, systemImage: model.extraTabs.contains(t) ? "checkmark" : "plus")
                        }
                    }
                } label: { Label("Add tab", systemImage: "plus").font(.system(size: 12, weight: .medium)) }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if session.messages.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ask about what you're reading").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(suggestions, id: \.1) { s in
                            Button { model.onSend(s.1) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: s.0).foregroundStyle(.secondary).frame(width: 20)
                                    Text(tr(s.1)).foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 14).padding(.vertical, 11)
                                .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.07)) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(session.messages) { m in MessageRow(message: m, streaming: session.isStreaming && m.id == session.messages.last?.id).id(m.id) }
                    }
                    .padding(16)
                }
            }
            .onChange(of: session.messages.last?.text) { _, _ in
                if let id = session.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: session.messages.count) { _, _ in
                if let id = session.messages.last?.id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    // MARK: Composer

    private var canSend: Bool { !model.draft.trimmingCharacters(in: .whitespaces).isEmpty }
    private var sendTint: Color { (busy || canSend) ? Color.accentColor : Color.secondary.opacity(0.5) }
    private var sendSymbol: String { busy ? "stop.circle.fill" : "arrow.up.circle.fill" }

    private var sendButton: some View {
        Button {
            if busy { if isAct { agent.stop() } else { session.stop() } } else { send() }
        } label: {
            Image(systemName: sendSymbol).font(.system(size: 26)).foregroundStyle(sendTint)
        }
        .buttonStyle(.plain)
        .help(busy ? "Stop  ⌘." : "Send  ↩")
        .accessibilityLabel(busy ? "Stop" : "Send")
    }

    private var micButton: some View {
        Button {
            let base = model.draft.isEmpty ? "" : model.draft + " "
            voice.toggle { text in model.draft = base + text }
        } label: {
            ZStack {
                if voice.isListening {
                    Circle().fill(Color.red.opacity(0.18)).frame(width: 30 + CGFloat(voice.level) * 10, height: 30 + CGFloat(voice.level) * 10)
                        .animation(.easeOut(duration: 0.08), value: voice.level)
                }
                Image(systemName: voice.isListening ? "mic.fill" : "mic").font(.system(size: 15))
                    .foregroundStyle(voice.isListening ? Color.red : Color.primary.opacity(0.55))
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(voice.isListening ? "Stop dictation" : "Dictate")
        .accessibilityLabel(voice.isListening ? "Stop dictation" : "Dictate")
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(isAct ? "Tell me what to do…" : "Ask anything…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($composerFocused)
                .accessibilityLabel(isAct ? "Tell the agent what to do" : "Ask the assistant")
                .onSubmit { send() }
                .padding(.vertical, 6)
            micButton
            sendButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.07)) }
        .padding(12)
    }

    private func send() {
        let t = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        voice.stop()
        model.draft = ""
        model.onSend(t)
    }
}

private struct Chip: View {
    let title: String
    let symbol: String
    let active: Bool
    let dimmed: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 150)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .background { Capsule().fill(active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.07)) }
            .opacity(dimmed ? 0.5 : 1)
        }
        .buttonStyle(.plain)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let streaming: Bool

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text).textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor) }
                    .foregroundStyle(.white)
                if !message.sources.isEmpty {
                    Label(message.sources.joined(separator: ", "), systemImage: "doc.text").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            if message.isError {
                Label(message.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.1)) }
            } else if message.text.isEmpty {
                TypingDots().frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownText(text: message.text).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TypingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color.secondary).frame(width: 7, height: 7).opacity(phase % 3 == i ? 1 : 0.3)
            }
        }
        .padding(.vertical, 8).onReceive(timer) { _ in phase += 1 }
        .accessibilityLabel("The assistant is thinking")
    }
}

/// Renders Markdown blocks (headings, lists, code, quotes) with inline bold/italic/code/links.
struct MarkdownText: View {
    let text: String

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t): inline(t).font(.system(size: level <= 1 ? 18 : (level == 2 ? 16 : 14), weight: .semibold)).padding(.top, 4)
                case .paragraph(let t): inline(t)
                case .bullet(let t): HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(.secondary); inline(t) }
                case .numbered(let n, let t): HStack(alignment: .firstTextBaseline, spacing: 8) { Text("\(n).").foregroundStyle(.secondary).monospacedDigit(); inline(t) }
                case .quote(let t):
                    inline(t).foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
                case .code(let c):
                    Text(c).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)) }
                case .rule: Divider()
                }
            }
        }
        .font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
    }
}


/// Past agent conversations: tap one to bring it back.
private struct AgentHistoryList: View {
    @ObservedObject var history: AgentHistoryStore
    let onPick: (AgentRunRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Past conversations").font(.headline)
                Spacer()
                if !history.runs.isEmpty { Button("Clear") { history.clear() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.callout) }
            }
            .padding(14)
            Divider().opacity(0.5)
            if history.runs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Nothing here yet — your finished conversations will appear here.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24).frame(width: 300)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(history.runs) { run in Row(run: run, onPick: onPick, onDelete: { history.remove(run.id) }) }
                    }
                    .padding(6)
                }
                .frame(width: 320, height: min(CGFloat(history.runs.count) * 58 + 12, 360))
            }
        }
    }

    private struct Row: View {
        let run: AgentRunRecord
        let onPick: (AgentRunRecord) -> Void
        let onDelete: () -> Void
        @State private var hover = false
        var body: some View {
            Button { onPick(run) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.bubble").foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: run.title).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                        Text(run.date.formatted(.relative(presentation: .named).locale(AppLanguage.currentLocale)) + (run.stepCount > 0 ? " · " + String(localized: "\(run.stepCount) steps") : ""))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if hover { Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Delete") }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
    }
}

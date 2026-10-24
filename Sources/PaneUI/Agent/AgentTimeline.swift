import PaneModel
import SwiftUI

/// The agent's side of the conversation: what you asked, each step it takes (live), and approvals.
struct AgentTimeline: View {
    @ObservedObject var agent: AgentSession
    @ObservedObject var macros: MacroStore
    let onSuggest: (String) -> Void
    let onSaveMacro: (String) -> Void
    let onAlwaysAllow: () -> Void

    private var lastPrompt: String? {
        for item in agent.items.reversed() { if case .user(_, let t) = item { return t } }
        return nil
    }

    private let suggestions: [(String, String)] = [
        ("square.stack.3d.up", "Group my open tabs by topic"),
        ("globe", "Open apple.com and tell me the newest iPhone's price"),
        ("moon.stars", "Switch to dark mode"),
        ("star", "Bookmark every open tab about Swift"),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if agent.items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                            Text("Tell me what to do in the browser").font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.top, 8)
                        Text("I can open and close tabs, fill in forms, search, organize bookmarks and change settings. You'll see every step, and I'll ask before anything risky.")
                            .font(.callout).foregroundStyle(.secondary)
                        if !macros.macros.isEmpty {
                            Text("My commands").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.top, 4)
                            ForEach(macros.macros) { m in
                                Button { onSuggest(m.prompt) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "bolt.fill").foregroundStyle(.orange).frame(width: 20)
                                        Text(verbatim: m.name).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)) }
                                }
                                .buttonStyle(.plain)
                                .contextMenu { Button("Delete", role: .destructive) { macros.remove(m.id) } }
                                .help(m.prompt)
                            }
                            Text("Examples").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.top, 4)
                        }
                        ForEach(suggestions, id: \.1) { s in
                            Button { onSuggest(tr(s.1)) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: s.0).foregroundStyle(.secondary).frame(width: 20)
                                    Text(tr(s.1)).foregroundStyle(.primary).multilineTextAlignment(.leading)
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
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(agent.items) { item in
                            row(item).id(item.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                        if let a = agent.pendingApproval {
                            ApprovalCard(request: a, onAnswer: { agent.answer(approve: $0) }, onAlwaysAllow: { onAlwaysAllow(); agent.answer(approve: true) }).id("approval")
                                .transition(.scale(scale: 0.95).combined(with: .opacity))
                        }
                        if !agent.isRunning, agent.pendingApproval == nil, let prompt = lastPrompt {
                            Button { onSaveMacro(prompt) } label: {
                                Label("Save as quick command", systemImage: "bolt.badge.plus").font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.plain).foregroundStyle(.orange).padding(.top, 4)
                            .transition(.opacity)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                    .animation(.spring(response: 0.38, dampingFraction: 0.82), value: agent.items.count)
                    .animation(.spring(response: 0.38, dampingFraction: 0.82), value: agent.pendingApproval)
                }
            }
            .onChange(of: agent.items.count) { _, _ in withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: agent.pendingApproval) { _, _ in withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    @ViewBuilder private func row(_ item: AgentItem) -> some View {
        switch item {
        case .user(_, let text):
            Text(text).textSelection(.enabled)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor) }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant(_, let text):
            MarkdownText(text: text).frame(maxWidth: .infinity, alignment: .leading)
        case .step(let s):
            StepRow(step: s)
        case .notice(_, let text, let isError):
            Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.callout).foregroundStyle(isError ? Color.orange : Color.secondary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill((isError ? Color.orange : Color.primary).opacity(0.09)) }
        }
    }
}

private struct StepRow: View {
    let step: AgentStep
    @State private var spin = false

    private var tint: Color {
        switch step.state {
        case .running: .accentColor
        case .waiting: .orange
        case .done: .green
        case .failed: .red
        case .denied: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: step.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.14)) }
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title).font(.system(size: 13)).lineLimit(2)
                if let n = step.note, step.state != .running {
                    Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Group {
                switch step.state {
                case .running: ProgressView().controlSize(.small)
                case .waiting: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .denied: Image(systemName: "nosign").foregroundStyle(.secondary)
                }
            }
            .transition(.scale.combined(with: .opacity))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(step.state == .running ? 0.09 : 0.05)) }
        .animation(.snappy(duration: 0.25), value: step.state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title), \(label)")
    }

    private var label: String {
        let key: String
        switch step.state { case .running: key = "in progress"; case .waiting: key = "waiting for your answer"; case .done: key = "done"; case .failed: key = "failed"; case .denied: key = "not allowed" }
        return tr(key)
    }
}

private struct ApprovalCard: View {
    let request: ApprovalRequest
    let onAnswer: (Bool) -> Void
    let onAlwaysAllow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Allow this?", systemImage: "hand.raised.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            HStack(spacing: 8) {
                Image(systemName: request.symbol).foregroundStyle(.secondary)
                Text(request.title).font(.system(size: 14, weight: .medium))
            }
            HStack(spacing: 8) {
                Button { onAnswer(true) } label: { Text("Allow").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button { onAnswer(false) } label: { Text("Don't allow").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            Button { onAlwaysAllow() } label: {
                Label("Always allow — don't ask again", systemImage: "checkmark.shield").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(.orange)
            .help("Turns on auto-approve. The agent still never types passwords or card numbers. You can turn it off in the panel header.")
        }
        .padding(14)
        .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange.opacity(0.12)) }
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.orange.opacity(0.4), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The agent asks permission: \(request.title)")
    }
}

import AppKit
import PaneModel
import SwiftUI

private let agentGradient = LinearGradient(colors: [.purple, .blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)

/// The agent's side of the conversation: what you asked, the steps it takes (live, grouped in one card) and its answers.
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

    /// Consecutive steps are shown together in one card.
    private enum Block: Identifiable {
        case user(id: String, text: String)
        case assistant(id: String, text: String)
        case steps(id: String, steps: [AgentStep])
        case notice(id: String, text: String, isError: Bool)
        var id: String {
            switch self { case .user(let i, _), .assistant(let i, _), .steps(let i, _), .notice(let i, _, _): return i }
        }
    }

    private var blocks: [Block] {
        var out: [Block] = []
        for item in agent.items {
            switch item {
            case .user(let id, let t): out.append(.user(id: id.uuidString, text: t))
            case .assistant(let id, let t): out.append(.assistant(id: id.uuidString, text: t))
            case .notice(let id, let t, let e): out.append(.notice(id: id.uuidString, text: t, isError: e))
            case .step(let s):
                if case .steps(let id, var steps)? = out.last { steps.append(s); out[out.count - 1] = .steps(id: id, steps: steps) }
                else { out.append(.steps(id: "steps-" + s.id, steps: [s])) }
            }
        }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if agent.items.isEmpty { emptyState } else { conversation }
            }
            .scrollIndicators(.hidden)
            .onChange(of: agent.items.count) { _, _ in withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: agent.pendingApproval) { _, _ in withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 10) {
                HeroOrb()
                Text("Tell me what to do in the browser").font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                Text("I can open and close tabs, fill in forms, search, organize bookmarks and change settings. You'll see every step, and I'll ask before anything risky.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity).padding(.top, 14).padding(.bottom, 4)

            if !macros.macros.isEmpty {
                sectionLabel("My commands")
                ForEach(macros.macros) { m in
                    SuggestionChip(symbol: "bolt.fill", text: m.name, tint: .orange, verbatim: true) { onSuggest(m.prompt) }
                        .contextMenu { Button("Delete", role: .destructive) { macros.remove(m.id) } }
                        .help(m.prompt)
                }
                sectionLabel("Examples")
            }
            ForEach(suggestions, id: \.1) { s in
                SuggestionChip(symbol: s.0, text: tr(s.1), tint: .accentColor, verbatim: true) { onSuggest(tr(s.1)) }
            }
        }
        .padding(16)
    }

    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.top, 4)
    }

    // MARK: Conversation

    private var conversation: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                blockView(block).id(block.id)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
            if let a = agent.pendingApproval {
                ApprovalCard(request: a, onAnswer: { agent.answer(approve: $0) }, onAlwaysAllow: { onAlwaysAllow(); agent.answer(approve: true) }).id("approval")
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
            if agent.isRunning, agent.pendingApproval == nil, !isLastStepRunning { Thinking().transition(.opacity) }
            if !agent.isRunning, agent.pendingApproval == nil, let prompt = lastPrompt {
                Button { onSaveMacro(prompt) } label: {
                    Label("Save as quick command", systemImage: "bolt.badge.plus").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.orange)
                .transition(.opacity)
            }
            Color.clear.frame(height: 1).id("end")
        }
        .padding(16)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: agent.items.count)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: agent.pendingApproval)
    }

    private var isLastStepRunning: Bool {
        if case .step(let s)? = agent.items.last { return s.state == .running || s.state == .waiting }
        return false
    }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case .user(_, let text):
            Text(verbatim: text).textSelection(.enabled)
                .font(.system(size: 13.5))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)) }
                .shadow(color: .accentColor.opacity(0.25), radius: 6, y: 3)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 36)
        case .assistant(_, let text):
            AssistantBubble(text: text)
        case .steps(_, let steps):
            StepsCard(steps: steps, isLive: agent.isRunning && steps.last?.id == lastStepID)
        case .notice(_, let text, let isError):
            Label { Text(verbatim: text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill") }
                .font(.callout).foregroundStyle(isError ? Color.orange : Color.secondary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill((isError ? Color.orange : Color.primary).opacity(0.09)) }
        }
    }

    private var lastStepID: String? {
        for item in agent.items.reversed() { if case .step(let s) = item { return s.id } }
        return nil
    }
}

// MARK: Pieces

private struct HeroOrb: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().fill(agentGradient).frame(width: 58, height: 58).blur(radius: on ? 14 : 8).opacity(0.55).scaleEffect(on ? 1.15 : 0.95)
            Circle().fill(agentGradient).frame(width: 46, height: 46)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            Image(systemName: "wand.and.stars").font(.system(size: 20, weight: .medium)).foregroundStyle(.white).symbolEffect(.pulse, options: .repeating.speed(0.5))
        }
        .frame(height: 70)
        .onAppear { withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { on = true } }
        .accessibilityHidden(true)
    }
}

private struct SuggestionChip: View {
    let symbol: String
    let text: String
    let tint: Color
    var verbatim = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).frame(width: 22, height: 22)
                    .background { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient) }
                Text(verbatim: text).foregroundStyle(.primary).multilineTextAlignment(.leading).font(.system(size: 13))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .paneGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: tint.opacity(0.10))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
    }
}

private struct Thinking: View {
    var body: some View {
        HStack(spacing: 8) {
            Avatar(size: 22)
            TimelineView(.animation(minimumInterval: 0.25)) { ctx in
                let n = Int(ctx.date.timeIntervalSinceReferenceDate * 4) % 4
                Text(verbatim: tr("Thinking") + String(repeating: ".", count: n)).font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityLabel("The agent is thinking")
    }
}

private struct Avatar: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "sparkles").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(agentGradient))
    }
}

private struct AssistantBubble: View {
    let text: String
    @State private var hover = false
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(size: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(text: text).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    withAnimation(.snappy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(.snappy) { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11)).contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hover || copied ? 1 : 0)
            }
        }
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
    }
}

/// Everything the agent did for one request, as one card with a vertical timeline. Collapses to a summary when it is done.
private struct StepsCard: View {
    let steps: [AgentStep]
    let isLive: Bool
    @State private var expanded: Bool?
    @State private var spin = false

    private var isExpanded: Bool { expanded ?? (isLive || steps.count <= 3) }
    private var running: AgentStep? { steps.last { $0.state == .running || $0.state == .waiting } }
    private var failed: Int { steps.filter { $0.state == .failed || $0.state == .denied }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.28)) { expanded = !isExpanded } } label: {
                HStack(spacing: 8) {
                    Image(systemName: headerSymbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(headerTint)
                        .symbolEffect(.pulse, isActive: isLive)
                    Text(verbatim: headerText).font(.system(size: 12.5, weight: .medium)).lineLimit(1).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                        StepLine(step: step, isFirst: i == 0, isLast: i == steps.count - 1)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.055)) }
        .overlay {
            if isLive {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AngularGradient(colors: [.purple, .blue, .teal, .purple], center: .center, angle: .degrees(spin ? 360 : 0)), lineWidth: 1.5)
                    .opacity(0.8)
                    .onAppear { withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { spin = true } }
            }
        }
        .animation(.snappy(duration: 0.25), value: isLive)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headerText)
    }

    private var headerSymbol: String { isLive ? "sparkles" : (failed == steps.count ? "xmark.circle.fill" : "checkmark.circle.fill") }
    private var headerTint: Color { isLive ? .accentColor : (failed == steps.count ? .red : .green) }
    private var headerText: String {
        if isLive, let r = running { return r.title }
        let n = steps.count
        let base = String(localized: "Done · \(n) steps")
        return failed > 0 && failed < n ? base + " · " + String(localized: "\(failed) didn't work") : base
    }
}

private struct StepLine: View {
    let step: AgentStep
    let isFirst: Bool
    let isLast: Bool

    private var tint: Color {
        switch step.state { case .running: .accentColor; case .waiting: .orange; case .done: .green; case .failed: .red; case .denied: .secondary }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Rectangle().fill(Color.primary.opacity(isFirst ? 0 : 0.14)).frame(width: 1.5, height: 6)
                ZStack {
                    Circle().fill(tint.opacity(0.16)).frame(width: 22, height: 22)
                    Image(systemName: step.symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                }
                Rectangle().fill(Color.primary.opacity(isLast ? 0 : 0.14)).frame(width: 1.5).frame(maxHeight: .infinity)
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: step.title).font(.system(size: 12.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let n = step.note, step.state != .running {
                    Text(verbatim: n).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            Spacer(minLength: 4)
            Group {
                switch step.state {
                case .running: ProgressView().controlSize(.mini)
                case .waiting: Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.system(size: 11))
                case .done: Image(systemName: "checkmark").foregroundStyle(.green).font(.system(size: 10, weight: .bold))
                case .failed: Image(systemName: "xmark").foregroundStyle(.red).font(.system(size: 10, weight: .bold))
                case .denied: Image(systemName: "nosign").foregroundStyle(.secondary).font(.system(size: 11))
                }
            }
            .padding(.top, 9)
            .transition(.scale.combined(with: .opacity))
        }
        .animation(.snappy(duration: 0.25), value: step.state)
        .accessibilityElement(children: .combine)
    }
}

private struct ApprovalCard: View {
    let request: ApprovalRequest
    let onAnswer: (Bool) -> Void
    let onAlwaysAllow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Allow this?", systemImage: "hand.raised.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            HStack(spacing: 10) {
                Image(systemName: request.symbol).foregroundStyle(.orange).frame(width: 30, height: 30)
                    .background { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.opacity(0.16)) }
                Text(verbatim: request.title).font(.system(size: 13.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { allow; deny }
                VStack(spacing: 8) { allow; deny }
            }
            .controlSize(.large)
            Button { onAlwaysAllow() } label: {
                Label("Always allow — don't ask again", systemImage: "checkmark.shield").font(.system(size: 11.5, weight: .medium))
            }
            .paneButtonStyle().tint(.orange)
            .help("Turns on auto-approve. The agent still never types passwords or card numbers. You can turn it off in the panel header.")
        }
        .padding(14)
        .background { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LinearGradient(colors: [Color.orange.opacity(0.16), Color.orange.opacity(0.08)], startPoint: .top, endPoint: .bottom)) }
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.orange.opacity(0.4), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The agent asks permission: \(request.title)")
    }

    private var allow: some View {
        Button { onAnswer(true) } label: { Text("Allow").frame(maxWidth: .infinity) }.paneButtonStyle(prominent: true).keyboardShortcut(.defaultAction)
    }
    private var deny: some View {
        Button { onAnswer(false) } label: { Text("Don't allow").frame(maxWidth: .infinity) }.paneButtonStyle()
    }
}

import SwiftUI

extension View {
    /// The system's Liquid Glass behind this view (it reacts to the pointer and to pressing); a soft material on older macOS.
    @ViewBuilder func paneGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(macOS 26.0, *), ProcessInfo.processInfo.environment["PANE_DEBUG_NOGLASS"] == nil {
            let base: SwiftUI.Glass = interactive ? .regular.interactive() : .regular
            self.glassEffect(tint.map { base.tint($0) } ?? base, in: shape)
        } else {
            self.background(tint?.opacity(0.35) ?? Color.clear, in: shape).background(.ultraThinMaterial, in: shape)
        }
    }

    /// A native glass push button (prominent = filled with the accent colour).
    @ViewBuilder func paneButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *), ProcessInfo.processInfo.environment["PANE_DEBUG_NOGLASS"] == nil {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

/// Groups glass shapes so they blend and morph together, like the system's own toolbars.
struct PaneGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26.0, *), ProcessInfo.processInfo.environment["PANE_DEBUG_NOGLASS"] == nil { GlassEffectContainer(spacing: spacing) { content() } } else { content() }
    }
}

extension View {
    /// The system's round glass button style (pointer highlight, press animation); a bordered round button before macOS 26.
    @ViewBuilder func paneIconButtonStyle(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *), ProcessInfo.processInfo.environment["PANE_DEBUG_NOGLASS"] == nil {
            self.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular).tint(tint)
        } else {
            self.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.regular).tint(tint)
        }
    }

    /// A tooltip that always appears (the system one doesn't inside floating panels). `anchor` says which edge the bubble lines up with.
    func paneTooltip(_ text: LocalizedStringKey, anchor: HorizontalAlignment = .center) -> some View { modifier(PaneTooltip(text: text, anchor: anchor)) }
}

private struct PaneTooltip: ViewModifier {
    let text: LocalizedStringKey
    let anchor: HorizontalAlignment
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    pending = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        if !Task.isCancelled { withAnimation(.snappy(duration: 0.14)) { shown = true } }
                    }
                } else { withAnimation(.snappy(duration: 0.1)) { shown = false } }
            }
            .overlay(alignment: Alignment(horizontal: anchor, vertical: .bottom)) {
                if shown {
                    Text(text)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.primary)
                        .lineLimit(3).multilineTextAlignment(.leading).frame(maxWidth: 230, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .paneGlass(RoundedRectangle(cornerRadius: 10, style: .continuous), interactive: false)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .alignmentGuide(.bottom) { d in d[.top] - 6 }
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(100)
                }
            }
            .zIndex(shown ? 100 : 0)
    }
}

/// A round glass button with an icon (the panel's header and composer buttons).
struct GlassIconButton: View {
    let symbol: String
    var tint: Color?
    var help: LocalizedStringKey
    var anchor: HorizontalAlignment = .center
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 16, height: 16)
        }
        .paneIconButtonStyle(tint: tint)
        .paneTooltip(help, anchor: anchor)
        .accessibilityLabel(help)
    }
}

/// Ask / Act: one glass capsule with a highlight that slides to the chosen side. Both sides have the same width, so nothing moves when you switch.
struct PaneSegmented<Value: Hashable>: View {
    struct Option: Identifiable { let value: Value; let title: LocalizedStringKey; let measure: [String]; var id: AnyHashable { AnyHashable(value) } }
    @Binding var selection: Value
    let options: [Option]
    var accent: Color
    @State private var hovered: AnyHashable?

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                let w = geo.size.width / CGFloat(options.count)
                Capsule().fill(accent)
                    .frame(width: w, height: geo.size.height)
                    .offset(x: CGFloat(options.firstIndex { $0.value == selection } ?? 0) * w)
                    .animation(.spring(response: 0.32, dampingFraction: 0.78), value: selection)
            }
            HStack(spacing: 0) {
                ForEach(options) { o in
                    let on = o.value == selection
                    Button { selection = o.value } label: {
                        ZStack {
                            ForEach(options.flatMap(\.measure), id: \.self) { Text(verbatim: $0).opacity(0) }
                            Text(o.title)
                        }
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(hovered == o.id ? 1 : 0.75))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle())
                    .onHover { h in hovered = h ? o.id : (hovered == o.id ? nil : hovered) }
                }
            }
        }
        .paneGlass(Capsule(), interactive: false)
        .fixedSize()
    }
}

/// Slight press-down feedback for custom buttons.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1).animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

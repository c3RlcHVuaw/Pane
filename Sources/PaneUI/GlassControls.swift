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

/// A round glass button with an icon (the panel's header and composer buttons).
struct GlassIconButton: View {
    let symbol: String
    var tint: Color?
    var size: CGFloat = 30
    var help: LocalizedStringKey
    var label: LocalizedStringKey
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.43, weight: .medium))
                .foregroundStyle(tint ?? Color.primary.opacity(0.75))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .paneGlass(Circle(), tint: tint?.opacity(0.28))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}

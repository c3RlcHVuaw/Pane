import AppKit
import PaneModel

/// Liquid Glass on macOS 26+, `NSVisualEffectView` below.
@MainActor
enum Glass {
    /// True when the OS can make glass react to the pointer by itself.
    static var supportsInteractiveGlass: Bool { if #available(macOS 27.0, *) { return true }; return false }

    static func surface(content: NSView, cornerRadius: CGFloat = 0, interactive: Bool = false, tint: NSColor? = nil) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let container: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            // The system's own hover and press response (shimmer, lift), available from macOS 27.
            if interactive, #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            glass.contentView = content
            container = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .sidebar
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = cornerRadius
            fx.layer?.cornerCurve = .continuous
            fx.layer?.masksToBounds = cornerRadius > 0
            fx.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                content.topAnchor.constraint(equalTo: fx.topAnchor),
                content.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            ])
            container = fx
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        return container
    }

    static func button(symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        ToolbarButton(symbol: symbol, label: tr(label), target: target, action: action)
    }
}

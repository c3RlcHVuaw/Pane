import AppKit
import PaneModel
import SwiftUI

struct ShortcutsGrid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard.fill").font(.title2).foregroundStyle(.secondary)
                Text("Keyboard Shortcuts").font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                Text("esc to close").font(.callout).foregroundStyle(.tertiary)
            }
            let columns = [GridItem(.flexible(), spacing: 28, alignment: .top), GridItem(.flexible(), spacing: 28, alignment: .top)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(ShortcutCatalog.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(tr(section.title), systemImage: section.symbol)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        ForEach(section.items) { item in
                            HStack { Text(verbatim: tr(item.name)).font(.system(size: 13)); Spacer(minLength: 12); KeyCaps(keys: item.keys) }
                        }
                    }
                }
            }
        }
        .padding(28)
    }
}

struct ShortcutsOverlayContent: View {
    var body: some View { ScrollView { ShortcutsGrid() }.scrollBounceBehavior(.basedOnSize) }
}

/// ⌘/ overlay listing every shortcut. Closes with Esc, ⌘/ or a click outside.
@MainActor
final class ShortcutsOverlayView: NSView {
    private let card: NSView
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        let host = NSHostingView(rootView: ShortcutsOverlayContent())
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        card = Glass.surface(content: host, cornerRadius: 26)
        super.init(frame: frame)
        wantsLayer = true
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor), card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            card.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 28),
            card.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -28),
            card.heightAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
        let preferred = card.widthAnchor.constraint(equalToConstant: 760)
        preferred.priority = .defaultHigh
        preferred.isActive = true
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("Keyboard shortcuts"))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    func present(in parent: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor), trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            topAnchor.constraint(equalTo: parent.topAnchor), bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0).cgColor
        card.alphaValue = 0
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0.01 : 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            card.animator().alphaValue = 1
            layer?.backgroundColor = NSColor.black.withAlphaComponent(Style.highContrast ? 0.35 : 0.2).cgColor
        }
        window?.makeFirstResponder(self)
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            card.animator().alphaValue = 0
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0).cgColor
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.removeFromSuperview() } })
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "/") { onClose?() }
        else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }
}

import AppKit
import PaneModel

/// Small glass capsule that confirms an action ("Bookmarked", "Downloaded …") and fades away.
@MainActor
final class ToastView: NSView {
    private static weak var current: ToastView?
    private var dismissWork: DispatchWorkItem?
    private var action: (() -> Void)?

    static func show(in parent: NSView, message: String, symbol: String, actionTitle: String? = nil,
                     duration: TimeInterval = 4.5, action: (() -> Void)? = nil) {
        current?.remove(animated: false)
        let t = ToastView(message: tr(message), symbol: symbol, actionTitle: actionTitle.map(tr), action: action)
        current = t
        t.present(in: parent, duration: duration)
    }

    private let card: NSView
    private var bottom: NSLayoutConstraint!

    private init(message: String, symbol: String, actionTitle: String?, action: (() -> Void)?) {
        self.action = action
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: String(message.prefix(300)))
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        var views: [NSView] = [icon, label]
        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        card = Glass.surface(content: content, cornerRadius: 18)
        super.init(frame: .zero)
        if let actionTitle {
            let b = NSButton(title: actionTitle, target: self, action: #selector(actionClicked))
            b.bezelStyle = .inline
            b.font = .systemFont(ofSize: 13, weight: .semibold)
            b.contentTintColor = .controlAccentColor
            views.append(b)
        }
        views.forEach(stack.addArrangedSubview)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -9),
            icon.widthAnchor.constraint(equalToConstant: 16),
        ])
        addSubview(card)
        setAccessibilityRole(.group)
        setAccessibilityLabel(message)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func present(in parent: NSView, duration: TimeInterval) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self)
        bottom = card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor), trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -22),
            heightAnchor.constraint(equalToConstant: 60),
            card.centerXAnchor.constraint(equalTo: centerXAnchor), bottom,
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -80),  // a long file name can't stretch the window
        ])
        card.alphaValue = 0
        bottom.constant = 6
        layoutSubtreeIfNeeded()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0.01 : 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            ctx.allowsImplicitAnimation = true
            card.animator().alphaValue = 1
            bottom.animator().constant = -8
        }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.remove(animated: true) } }
        dismissWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: w)
    }

    @objc private func actionClicked() {
        let a = action
        remove(animated: true)
        a?()
    }

    private func remove(animated: Bool) {
        dismissWork?.cancel()
        if ToastView.current === self { ToastView.current = nil }
        guard animated else { removeFromSuperview(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            card.animator().alphaValue = 0
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.removeFromSuperview() } })
    }

    // Only the card takes clicks; the rest of the strip lets the page through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Link preview in the page's bottom-left corner, like other browsers' status bubble.
@MainActor
final class StatusBubble: NSView {
    private let label = NSTextField(labelWithString: "")
    private let card: NSView

    init() {
        let content = NSView()
        card = Glass.surface(content: content, cornerRadius: 10)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        // The text of a link under the pointer can be thousands of characters long: it must never decide how wide the window is.
        label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        alphaValue = 0
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func attach(to parent: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -8),
            widthAnchor.constraint(lessThanOrEqualTo: parent.widthAnchor, multiplier: 0.6),
            widthAnchor.constraint(lessThanOrEqualToConstant: 620),
        ])
    }

    func bringToFront() { superview?.addSubview(self, positioned: .above, relativeTo: nil) }

    func set(_ text: String) {
        if !text.isEmpty { label.stringValue = String(text.prefix(300)) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = text.isEmpty ? 0.2 : 0.12
            animator().alphaValue = text.isEmpty ? 0 : 1
        }
    }

    // Never intercept clicks meant for the page.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}


/// Shown over a page whose process died, with a one-click way back.
@MainActor
final class CrashOverlay: NSView {
    init(reason: String, onReload: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.textBackgroundColor.cgColor }
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        let title = NSTextField(labelWithString: tr("This page \(reason)"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "Something went wrong while showing this tab. Your other tabs are fine.")
        detail.alignment = .center
        detail.textColor = .secondaryLabelColor
        let button = PillButton(title: tr("Reload Page"), symbol: "arrow.clockwise", target: nil, action: nil)
        button.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let handler = ReloadHandler(onReload)
        button.target = handler
        button.action = #selector(ReloadHandler.fire)
        objc_setAssociatedObject(button, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        let stack = NSStackView(views: [icon, title, detail, button])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("This page \(reason)"))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private final class ReloadHandler: NSObject {
        let action: () -> Void
        init(_ a: @escaping () -> Void) { action = a }
        @MainActor @objc func fire() { action() }
    }
}


/// "Private" / profile name, shown in the sidebar corner so you always know which window you're in.
@MainActor
final class ProfileBadge: NSView {
    init(text: String, symbol: String, color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color
        icon.imageScaling = .scaleProportionallyDown
        let label = NSTextField(labelWithString: tr(text))
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [icon, label])
        row.spacing = 4
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 3), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            icon.widthAnchor.constraint(equalToConstant: 12), icon.heightAnchor.constraint(equalToConstant: 12),
            widthAnchor.constraint(lessThanOrEqualToConstant: 96),
        ])
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor }
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(symbol == "lock.shield.fill" ? tr("Private window") : tr("Profile") + " \(text)")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    override func viewDidChangeEffectiveAppearance() {
        // The colour is fixed, only the translucency needs re-resolving.
        needsLayout = true
    }
}


/// A plain view that reports the pointer entering and leaving it (used for the sidebar's edge peek).
@MainActor
final class HoverBox: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

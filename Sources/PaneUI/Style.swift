import AppKit

/// Shared look: neutral fills that respect Increase Contrast.
@MainActor
enum Style {
    static var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static func fill(_ alpha: CGFloat) -> NSColor {
        NSColor.labelColor.withAlphaComponent(highContrast ? min(1, alpha * 2.2) : alpha)
    }
}

/// Opaque page card. Re-resolves its dynamic colours when the appearance changes.
final class WebHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { refresh() }
    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// Thin accent line that sweeps along the address pill while a page loads.
@MainActor
final class LoadingBar: NSView {
    private let runner = CALayer()
    private var active = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 1
        runner.cornerRadius = 1
        layer?.addSublayer(runner)
        isHidden = true
        recolor()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { recolor() }
    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance { runner.backgroundColor = NSColor.controlAccentColor.cgColor }
    }
    override func layout() {
        super.layout()
        if active { restart() }
    }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        isHidden = !on
        on ? restart() : runner.removeAllAnimations()
    }

    private func restart() {
        runner.removeAllAnimations()
        guard bounds.width > 0 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            runner.frame = bounds; runner.opacity = 0.5
            return
        }
        let w = bounds.width * 0.35
        runner.opacity = 1
        runner.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -w / 2
        a.toValue = bounds.width + w / 2
        a.duration = 1.1
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        runner.add(a, forKey: "sweep")
    }
}

/// Address field that reports focus so the toolbar can switch between "domain only" and "full URL".
final class AddressField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

/// Capsule button with a visible fill that works on top of glass (system glass buttons vanish against glass).
@MainActor
final class PillButton: NSButton {
    private var hovered = false { didSet { updateBackground() } }
    override var isHighlighted: Bool { didSet { updateBackground() } }

    init(title: String, symbol: String?, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        font = .systemFont(ofSize: 13, weight: .medium)
        contentTintColor = .labelColor
        self.title = title
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? nil : title)
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            imageHugsTitle = true
        }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        updateBackground()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    override func viewDidChangeEffectiveAppearance() { updateBackground() }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Style.fill(isHighlighted ? 0.2 : (hovered ? 0.14 : 0.08)).cgColor
        }
    }
}


/// A toolbar icon button on its own piece of interactive Liquid Glass: the system supplies the hover and press response.
/// Put `host` (not the button) into layouts. Where the OS can't do that, a soft fill stands in.
@MainActor
final class ToolbarButton: NSButton {
    /// The glass the button sits on.
    private(set) lazy var host: NSView = {
        let glass = Glass.surface(content: self, cornerRadius: 15, interactive: true)
        NSLayoutConstraint.activate([glass.widthAnchor.constraint(equalToConstant: 36), glass.heightAnchor.constraint(equalToConstant: 30)])
        return glass
    }()
    private var fallbackHover = false { didSet { updateFallback() } }
    override var isHighlighted: Bool { didSet { updateFallback() } }
    override var isEnabled: Bool { didSet { contentTintColor = isEnabled ? .labelColor : .tertiaryLabelColor; updateFallback() } }
    override var isHidden: Bool { didSet { if isHidden != host.isHidden { host.isHidden = isHidden } } }

    init(symbol: String, label: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        symbolConfiguration = .init(pointSize: 14, weight: .medium)
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 15
        contentTintColor = .labelColor
        toolTip = label
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Fallback feedback for systems without interactive glass

    override func viewDidChangeEffectiveAppearance() { updateFallback() }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        guard !Glass.supportsInteractiveGlass else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { fallbackHover = true }
    override func mouseExited(with event: NSEvent) { fallbackHover = false }

    private func updateFallback() {
        guard !Glass.supportsInteractiveGlass else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Style.fill(!isEnabled ? 0 : (isHighlighted ? 0.2 : (fallbackHover ? 0.12 : 0))).cgColor
        }
    }
}

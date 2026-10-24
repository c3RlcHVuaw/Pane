import AppKit
import PaneModel

extension NSPasteboard.PasteboardType {
    static let paneTab = NSPasteboard.PasteboardType("com.pane.tab")
    static let paneBookmark = NSPasteboard.PasteboardType("com.pane.bookmark")
}

enum GroupPalette {
    static let colors: [(name: String, color: NSColor)] = [
        ("Blue", .systemBlue), ("Purple", .systemPurple), ("Pink", .systemPink), ("Red", .systemRed),
        ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen), ("Teal", .systemTeal),
    ]
    static func color(_ i: Int) -> NSColor { colors[((i % colors.count) + colors.count) % colors.count].color }
}

func tabIcon(_ image: NSImage?) -> NSImage {
    image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
}

/// Rounded highlight instead of the stock full-width source-list selection.
final class PaneRowView: NSTableRowView {
    /// The selection is a pill the sidebar slides between rows; the row itself draws nothing.
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }

    private var hovered = false { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func drawBackground(in dirtyRect: NSRect) {
        guard hovered, !isSelected else { return }
        Style.fill(0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 9, yRadius: 9).fill()
    }
}

final class TabCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let close = NSButton()
    private let spinner = NSProgressIndicator()
    private let speaker = NSButton()
    private var titleToEdge: NSLayoutConstraint!
    private var titleToClose: NSLayoutConstraint!
    private var titleToSpeaker: NSLayoutConstraint!
    private var speakerAtEdge: NSLayoutConstraint!
    private var speakerBesideClose: NSLayoutConstraint!
    private var muted = false
    var onToggleMute: ((UUID) -> Void)?
    private var hovered = false { didSet { updateAccessories() } }
    private var audible = false
    private var tracking: NSTrackingArea?
    private(set) var tabID: UUID?
    var onClose: ((UUID) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 4
        icon.layer?.masksToBounds = true
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 13)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        close.isBordered = false
        close.imageScaling = .scaleProportionallyDown
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(didClose)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.isHidden = true
        close.setAccessibilityLabel(tr("Close Tab"))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        speaker.isBordered = false
        speaker.contentTintColor = .secondaryLabelColor
        speaker.imageScaling = .scaleProportionallyDown
        speaker.target = self
        speaker.action = #selector(didToggleMute)
        speaker.translatesAutoresizingMaskIntoConstraints = false
        speaker.isHidden = true
        addSubview(icon); addSubview(spinner); addSubview(title); addSubview(close); addSubview(speaker)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14), spinner.heightAnchor.constraint(equalToConstant: 14),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            speaker.centerYAnchor.constraint(equalTo: centerYAnchor),
            speaker.widthAnchor.constraint(equalToConstant: 14), speaker.heightAnchor.constraint(equalToConstant: 14),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16), close.heightAnchor.constraint(equalToConstant: 16),
        ])
        // The title uses all the room it can; the close button / speaker only take space when they are showing.
        speakerAtEdge = speaker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9)
        speakerBesideClose = speaker.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2)
        titleToEdge = title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        titleToClose = title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4)
        titleToSpeaker = title.trailingAnchor.constraint(equalTo: speaker.leadingAnchor, constant: -4)
        updateAccessories()
    }

    private func updateAccessories() {
        let showSpeaker = audible || muted
        close.isHidden = !hovered
        speaker.isHidden = !showSpeaker
        speaker.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                accessibilityDescription: muted ? "Unmute tab" : "Mute tab")
        speaker.toolTip = muted ? "Unmute tab" : "Mute tab"
        speaker.setAccessibilityLabel(muted ? "Unmute tab" : "Mute tab")
        titleToEdge.isActive = false; titleToClose.isActive = false; titleToSpeaker.isActive = false
        speakerAtEdge.isActive = false; speakerBesideClose.isActive = false
        (hovered ? speakerBesideClose : speakerAtEdge).isActive = true
        // With the speaker showing, the title stops at it (it sits left of the close button while hovering).
        (showSpeaker ? titleToSpeaker : (hovered ? titleToClose : titleToEdge)).isActive = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ tab: TabItem, icon image: NSImage?, dimmed: Bool, active: Bool = false, loading: Bool = false, audible: Bool = false, muted: Bool = false) {
        tabID = tab.id
        let isStart = tab.url.isEmpty
        icon.image = isStart ? NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil) : tabIcon(image)
        icon.contentTintColor = (image == nil || isStart) ? .secondaryLabelColor : nil
        icon.alphaValue = dimmed ? 0.5 : 1
        icon.isHidden = loading
        loading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        title.stringValue = tab.displayTitle
        title.font = .systemFont(ofSize: 13, weight: active ? .medium : .regular)
        title.textColor = dimmed ? .secondaryLabelColor : .labelColor
        self.audible = audible
        self.muted = muted
        updateAccessories()
        toolTip = tab.url.isEmpty ? tab.displayTitle : "\(tab.displayTitle)\n\(URL(string: tab.url)?.host ?? tab.url)"
        setAccessibilityLabel(audible ? "\(tab.displayTitle), playing audio" : tab.displayTitle)
    }

    @objc private func didClose() { if let id = tabID { onClose?(id) } }
    @objc private func didToggleMute() { if let id = tabID { onToggleMute?(id) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

final class GroupCellView: NSTableCellView {
    private let dot = NSView()
    private let symbolView = NSImageView()
    private let title = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.contentTintColor = .tertiaryLabelColor
        symbolView.isHidden = true
        addSubview(symbolView)
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 14), symbolView.heightAnchor.constraint(equalToConstant: 14),
        ])
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        addSubview(dot); addSubview(title)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, color: NSColor?, symbol: String? = nil, count: Int) {
        let text = NSMutableAttributedString(string: name, attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        if count > 0 { text.append(NSAttributedString(string: "  \(count)", attributes: [.foregroundColor: NSColor.tertiaryLabelColor])) }
        title.attributedStringValue = text
        dot.layer?.backgroundColor = (color ?? .tertiaryLabelColor).cgColor
        dot.isHidden = color == nil || symbol != nil
        symbolView.isHidden = symbol == nil
        if let symbol { symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        setAccessibilityLabel(name)
    }
}

/// Outline view that asks its owner for a per-row context menu (or the background menu on empty space).
final class ContextOutlineView: NSOutlineView {
    var menuProvider: ((Int) -> NSMenu?)?
    var backgroundMenuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? (menuProvider?(row) ?? backgroundMenuProvider?()) : backgroundMenuProvider?()
    }
}

/// Rounded highlight behind the active tab; glides to the new row instead of jumping.
final class SelectionPill: NSView {
    private var placed = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        alphaValue = 0
        refreshColor()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private func refreshColor() { effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Style.fill(0.14).cgColor } }
    override func viewDidChangeEffectiveAppearance() { refreshColor() }

    func move(to rect: NSRect) {
        guard placed, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            frame = rect; alphaValue = 1; placed = true; return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            ctx.allowsImplicitAnimation = true
            animator().frame = rect
            animator().alphaValue = 1
        }
    }
    func hide() {
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; animator().alphaValue = 0 }
        placed = false
    }
}

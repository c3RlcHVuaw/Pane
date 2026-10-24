import AppKit
import PaneModel

struct PinnedEntry {
    var id: UUID
    var title: String
    var icon: NSImage?
    var isActive: Bool
}

@MainActor
final class PinTile: NSView, NSDraggingSource {
    let entryID: UUID
    var onSelect: ((UUID) -> Void)?
    var menuProvider: ((UUID) -> NSMenu?)?
    private var downEvent: NSEvent?
    private let icon = NSImageView()
    private var active = false
    private var hovered = false { didSet { updateBackground() } }

    init(entry: PinnedEntry) {
        entryID = entry.id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 5
        icon.layer?.masksToBounds = true
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        update(entry)
        setAccessibilityRole(.button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(_ e: PinnedEntry) {
        icon.image = tabIcon(e.icon)
        icon.contentTintColor = e.icon == nil ? .secondaryLabelColor : nil
        toolTip = e.title
        setAccessibilityLabel(tr("Pinned: \(e.title)"))
        active = e.isActive
        needsDisplay = true
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Style.fill(hovered ? 0.12 : (active ? 0.16 : 0.07)).cgColor
            layer?.borderWidth = active ? 1.5 : 0
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { updateBackground() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) { downEvent = event }
    override func mouseUp(with event: NSEvent) { if downEvent != nil { onSelect?(entryID) }; downEvent = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, hypot(event.locationInWindow.x - down.locationInWindow.x,
                                          event.locationInWindow.y - down.locationInWindow.y) > 4 else { return }
        downEvent = nil
        let item = NSPasteboardItem()
        item.setString(entryID.uuidString, forType: .paneTab)
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [drag], event: down, source: self)
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(entryID) }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

    private func snapshot() -> NSImage {
        let img = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep); img.addRepresentation(rep)
        }
        return img
    }
}

/// Wrapping grid of pinned tab icons. Accepts tab drops to pin or reorder.
@MainActor
final class PinnedGridView: NSView {
    static let cell: CGFloat = 40, gap: CGFloat = 6, inset: CGFloat = 8

    var onSelect: ((UUID) -> Void)?
    var onDrop: ((UUID, UUID?) -> Void)?  // dragged id, pin to insert before
    var menuProvider: ((UUID) -> NSMenu?)?
    var backgroundMenuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { backgroundMenuProvider?() }
    private var tiles: [PinTile] = []
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.paneTab])
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("Pinned tabs"))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setEntries(_ entries: [PinnedEntry]) {
        if tiles.map(\.entryID) != entries.map(\.id) {
            tiles.forEach { $0.removeFromSuperview() }
            tiles = entries.map { e in
                let t = PinTile(entry: e)
                t.onSelect = { [weak self] id in self?.onSelect?(id) }
                t.menuProvider = { [weak self] id in self?.menuProvider?(id) }
                addSubview(t)
                return t
            }
        }
        for (t, e) in zip(tiles, entries) { t.update(e) }
        isHidden = entries.isEmpty
        needsLayout = true
    }

    private var columns: Int {
        max(1, Int((bounds.width - Self.inset * 2 + Self.gap) / (Self.cell + Self.gap)))
    }

    override func layout() {
        super.layout()
        let cols = columns
        for (i, t) in tiles.enumerated() {
            let r = i / cols, c = i % cols
            t.frame = NSRect(x: Self.inset + CGFloat(c) * (Self.cell + Self.gap),
                             y: bounds.height - Self.inset - Self.cell - CGFloat(r) * (Self.cell + Self.gap),
                             width: Self.cell, height: Self.cell)
        }
        let rows = tiles.isEmpty ? 0 : (tiles.count + cols - 1) / cols
        let h = tiles.isEmpty ? 0 : CGFloat(rows) * (Self.cell + Self.gap) + Self.inset - Self.gap + 4
        if heightConstraint.constant != h { heightConstraint.constant = h }
    }

    // MARK: Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .move }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .move }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let s = sender.draggingPasteboard.string(forType: .paneTab), let id = UUID(uuidString: s) else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        let target = tiles.first { $0.frame.insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2).contains(p) }?.entryID
        onDrop?(id, target == id ? nil : target)
        return true
    }
}

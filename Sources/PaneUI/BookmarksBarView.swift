import AppKit
import PaneModel

@MainActor
final class BarItemView: NSView, NSDraggingSource {
    let node: BookmarkNode
    var onClick: ((BarItemView, NSEvent) -> Void)?
    var menuProvider: ((BookmarkNode) -> NSMenu?)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovered = false { didSet { updateBackground() } }
    private var downEvent: NSEvent?

    init(node: BookmarkNode, icon image: NSImage?) {
        self.node = node
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        icon.image = node.isFolder ? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) : tabIcon(image)
        icon.contentTintColor = (node.isFolder || image == nil) ? .secondaryLabelColor : nil
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 3
        icon.layer?.masksToBounds = true
        label.stringValue = node.displayTitle
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(node.isFolder ? "\(node.displayTitle), folder" : node.displayTitle)
        toolTip = node.url ?? node.displayTitle
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var idealWidth: CGFloat { min(180, 7 + 14 + 5 + ceil(label.intrinsicContentSize.width) + 7) }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovered ? Style.fill(0.12).cgColor : nil
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
    override func mouseUp(with event: NSEvent) { if downEvent != nil { onClick?(self, event) }; downEvent = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, hypot(event.locationInWindow.x - down.locationInWindow.x,
                                          event.locationInWindow.y - down.locationInWindow.y) > 4 else { return }
        downEvent = nil
        let item = NSPasteboardItem()
        item.setString(node.id.uuidString, forType: .paneBookmark)
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(bounds, contents: nil)
        beginDraggingSession(with: [drag], event: down, source: self)
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(node) }
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
}

/// Single row of bookmarks under the address bar. Items that don't fit collapse into a "»" menu.
@MainActor
final class BookmarksBarView: NSView {
    private let store: BookmarkStore
    var icon: (String) -> NSImage? = { _ in nil }
    var onOpen: ((BookmarkNode, _ newTab: Bool) -> Void)?
    var onDropTab: ((UUID, UUID?) -> Void)?
    var menuProvider: ((BookmarkNode) -> NSMenu?)?
    private var items: [BarItemView] = []
    private let overflow = NSButton()
    private var shown: [BookmarkNode] = []
    private let hint = NSTextField(labelWithString: tr("Bookmarks you add appear here — press ⌘D on any page"))

    init(store: BookmarkStore) {
        self.store = store
        super.init(frame: .zero)
        overflow.image = NSImage(systemSymbolName: "chevron.right.2", accessibilityDescription: "More Bookmarks")
        overflow.isBordered = false
        overflow.contentTintColor = .secondaryLabelColor
        overflow.target = self
        overflow.action = #selector(showOverflow)
        overflow.setAccessibilityLabel(tr("More Bookmarks"))
        overflow.isHidden = true
        addSubview(overflow)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        addSubview(hint)
        registerForDraggedTypes([.paneTab, .paneBookmark])
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(tr("Bookmarks Bar"))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func reload() {
        items.forEach { $0.removeFromSuperview() }
        items = store.bar.children.map { n in
            let v = BarItemView(node: n, icon: n.url.flatMap(icon))
            v.onClick = { [weak self] view, event in self?.clicked(view, event) }
            v.menuProvider = { [weak self] n in self?.menuProvider?(n) }
            addSubview(v, positioned: .below, relativeTo: overflow)
            return v
        }
        hint.isHidden = !items.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        hint.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 24), height: 16)
        let h: CGFloat = 24, y = (bounds.height - h) / 2
        let pad: CGFloat = 8
        var x: CGFloat = pad
        var overflowFrom: Int?
        let reserve: CGFloat = 26
        for (i, v) in items.enumerated() {
            let w = v.idealWidth
            let remaining = items.count - i - 1
            if x + w + (remaining > 0 ? reserve : 0) > bounds.width - pad && overflowFrom == nil && !(remaining == 0 && x + w <= bounds.width - pad) {
                overflowFrom = i
            }
            if overflowFrom != nil { v.isHidden = true; continue }
            v.isHidden = false
            v.frame = NSRect(x: x, y: y, width: w, height: h)
            x += w + 2
        }
        shown = overflowFrom.map { Array(store.bar.children[$0...]) } ?? []
        overflow.isHidden = overflowFrom == nil
        overflow.frame = NSRect(x: bounds.width - 24 - 4, y: y, width: 24, height: h)
    }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); needsLayout = true }

    // MARK: Clicks and menus

    private func clicked(_ view: BarItemView, _ event: NSEvent) {
        if view.node.isFolder {
            let m = menu(for: view.node.children)
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 2), in: view)
        } else {
            onOpen?(view.node, event.modifierFlags.contains(.command))
        }
    }

    @objc private func showOverflow() {
        menu(for: shown).popUp(positioning: nil, at: NSPoint(x: 0, y: overflow.bounds.height + 2), in: overflow)
    }

    private func menu(for nodes: [BookmarkNode]) -> NSMenu {
        let m = NSMenu()
        if nodes.isEmpty { let e = NSMenuItem(title: tr("Empty"), action: nil, keyEquivalent: ""); e.isEnabled = false; m.addItem(e) }
        for n in nodes {
            let item = NSMenuItem(title: n.displayTitle, action: n.isFolder ? nil : #selector(menuOpen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = n.id
            if n.isFolder {
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                item.submenu = menu(for: n.children)
            } else {
                item.image = n.url.flatMap(icon).map { img in
                    let c = img.copy() as! NSImage; c.size = NSSize(width: 14, height: 14); return c
                }
            }
            m.addItem(item)
        }
        return m
    }

    @objc private func menuOpen(_ s: NSMenuItem) {
        guard let id = s.representedObject as? UUID, let n = store.node(id) else { return }
        onOpen?(n, NSEvent.modifierFlags.contains(.command))
    }

    // MARK: Drops

    private func insertionTarget(_ info: NSDraggingInfo) -> UUID? {
        let p = convert(info.draggingLocation, from: nil)
        return items.first { !$0.isHidden && p.x < $0.frame.midX }?.node.id
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .move }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .move }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let before = insertionTarget(sender)
        if let s = pb.string(forType: .paneBookmark), let id = UUID(uuidString: s) {
            return store.move(id, toFolder: store.bar.id, before: before)
        }
        if let s = pb.string(forType: .paneTab), let id = UUID(uuidString: s) {
            onDropTab?(id, before)
            return true
        }
        return false
    }
}

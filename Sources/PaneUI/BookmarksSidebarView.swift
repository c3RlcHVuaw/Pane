import AppKit
import PaneModel

final class BookmarkItem: NSObject {
    let id: UUID
    init(_ id: UUID) { self.id = id }
}

final class BookmarkCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 13)
        addSubview(icon); addSubview(title)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ n: BookmarkNode, icon image: NSImage?, isRoot: Bool) {
        title.stringValue = n.displayTitle
        title.font = .systemFont(ofSize: isRoot ? 12 : 13, weight: isRoot ? .semibold : .regular)
        title.textColor = isRoot ? .secondaryLabelColor : .labelColor
        if n.isFolder {
            icon.image = NSImage(systemSymbolName: isRoot ? "star.square.on.square" : "folder", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
        } else {
            icon.image = tabIcon(image)
            icon.contentTintColor = image == nil ? .secondaryLabelColor : nil
        }
        setAccessibilityLabel(n.isFolder ? "\(n.displayTitle), folder" : n.displayTitle)
    }
}

/// "All Bookmarks": the full tree with folders, drag to reorder, context menus and import.
@MainActor
final class BookmarksSidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let store: BookmarkStore
    var icon: (String) -> NSImage? = { _ in nil }
    var onOpen: ((BookmarkNode, _ newTab: Bool) -> Void)?
    var onDropTab: ((UUID, UUID, UUID?) -> Void)?  // tab id, folder, before
    var importMenu: () -> NSMenu = { NSMenu() }

    private let outline = ContextOutlineView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No bookmarks yet.\n\nPress ⌘D to bookmark a page, or import from Arc, Chrome or Safari.")
    private var items: [UUID: BookmarkItem] = [:]
    private var expanded: Set<UUID> = []
    private var syncing = false
    private var animatingUntil = Date.distantPast
    private var reloadPending = false

    init(store: BookmarkStore) {
        self.store = store
        super.init(frame: .zero)
        expanded = [store.bar.id, store.other.id]
        build()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bm"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.indentationPerLevel = 12
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.rowHeight = 28
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.registerForDraggedTypes([.paneBookmark, .paneTab])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .gap
        outline.setAccessibilityLabel(tr("All Bookmarks"))
        outline.menuProvider = { [weak self] row in self?.menu(forRow: row) }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: tr("All Bookmarks"))
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        let newFolder = PillButton(title: tr("Folder"), symbol: "folder.badge.plus", target: self, action: #selector(newFolderClicked))
        let importButton = PillButton(title: tr("Import"), symbol: "square.and.arrow.down", target: self, action: #selector(importClicked(_:)))
        let bottom = NSStackView(views: [newFolder, importButton])
        bottom.spacing = 8
        bottom.distribution = .fillEqually
        bottom.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        addSubview(heading); addSubview(scroll); addSubview(bottom); addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 48),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    func reload() {
        guard !reloadPending else { return }
        reloadPending = true
        let wait = max(0, animatingUntil.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.01) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadPending = false
                if self.animatingUntil.timeIntervalSinceNow > 0 { self.reload() } else { self.performReload() }
            }
        }
    }

    func outlineViewItemWillExpand(_ n: Notification) { animatingUntil = Date().addingTimeInterval(0.45) }
    func outlineViewItemWillCollapse(_ n: Notification) { animatingUntil = Date().addingTimeInterval(0.45) }

    /// Re-applies icons to the rows on screen without touching the tree (safe during animations).
    func refreshIcons() {
        let rows = outline.rows(in: outline.visibleRect)
        for r in rows.location..<(rows.location + rows.length) {
            guard let item = outline.item(atRow: r), let n = node(item),
                  let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: false) as? BookmarkCellView else { continue }
            cell.configure(n, icon: n.url.flatMap(icon), isRoot: store.isRoot(n.id))
        }
    }

    private func performReload() {
        syncing = true
        defer { syncing = false }
        var live = Set<UUID>()
        func collect(_ n: BookmarkNode) { live.insert(n.id); n.children.forEach(collect) }
        store.roots.forEach(collect)
        items = items.filter { live.contains($0.key) }
        for id in live where items[id] == nil { items[id] = BookmarkItem(id) }
        outline.reloadData()
        emptyLabel.isHidden = !(store.bar.children.isEmpty && store.other.children.isEmpty)
        for id in expanded { if let i = items[id], store.node(id) != nil { outline.expandItem(i) } }
    }

    // MARK: Data source

    private func node(_ item: Any?) -> BookmarkNode? { (item as? BookmarkItem).flatMap { store.node($0.id) } }
    private func kids(_ item: Any?) -> [BookmarkNode] { item == nil ? store.roots : (node(item)?.children ?? []) }

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { kids(item).count }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { items[kids(item)[index].id]! }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { node(item)?.isFolder ?? false }

    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let n = node(item) else { return nil }
        let rid = NSUserInterfaceItemIdentifier("bmcell")
        let cell = (ov.makeView(withIdentifier: rid, owner: self) as? BookmarkCellView) ?? { let c = BookmarkCellView(); c.identifier = rid; return c }()
        cell.configure(n, icon: n.url.flatMap(icon), isRoot: store.isRoot(n.id))
        return cell
    }
    func outlineView(_ ov: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { PaneRowView() }
    func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }
    func outlineViewItemDidExpand(_ n: Notification) { track(n, true) }
    func outlineViewItemDidCollapse(_ n: Notification) { track(n, false) }
    private func track(_ n: Notification, _ open: Bool) {
        guard !syncing, let i = n.userInfo?["NSObject"] as? BookmarkItem else { return }
        if open { expanded.insert(i.id) } else { expanded.remove(i.id) }
    }

    @objc private func clicked() {
        guard outline.clickedRow >= 0, let item = outline.item(atRow: outline.clickedRow), let n = node(item) else { return }
        if n.isFolder {
            outline.isItemExpanded(item) ? outline.collapseItem(item) : outline.expandItem(item)
        } else {
            onOpen?(n, NSEvent.modifierFlags.contains(.command))
        }
    }

    // MARK: Drag & drop

    func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let n = node(item), !store.isRoot(n.id) else { return nil }
        let p = NSPasteboardItem()
        p.setString(n.id.uuidString, forType: .paneBookmark)
        return p
    }

    private func uuid(_ info: NSDraggingInfo, _ type: NSPasteboard.PasteboardType) -> UUID? {
        info.draggingPasteboard.string(forType: type).flatMap(UUID.init(uuidString:))
    }

    func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard uuid(info, .paneBookmark) != nil || uuid(info, .paneTab) != nil else { return [] }
        guard let target = node(item) else { return [] }  // roots are fixed
        if target.isFolder { return .move }
        ov.setDropItem(ov.parent(forItem: item), dropChildIndex: ov.childIndex(forItem: item!))
        return .move
    }

    func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = node(item) else { return false }
        let before = index >= 0 && index < folder.children.count ? folder.children[index].id : nil
        if let id = uuid(info, .paneBookmark) { return store.move(id, toFolder: folder.id, before: before) }
        if let t = uuid(info, .paneTab) { onDropTab?(t, folder.id, before); return true }
        return false
    }

    // MARK: Menus

    private func menu(forRow row: Int) -> NSMenu? {
        guard let item = outline.item(atRow: row), let n = node(item) else { return nil }
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: ""); mi.target = self; mi.representedObject = n.id; m.addItem(mi)
        }
        if !n.isFolder { add("Open", #selector(openItem(_:))); add("Open in New Tab", #selector(openItemInNewTab(_:))); m.addItem(.separator()) }
        if n.isFolder { add("New Folder", #selector(newFolderIn(_:))) }
        if !store.isRoot(n.id) { add("Rename…", #selector(rename(_:))); add("Delete", #selector(delete(_:))) }
        return m.items.isEmpty ? nil : m
    }

    @objc private func openItem(_ s: NSMenuItem) { if let id = s.representedObject as? UUID, let n = store.node(id) { onOpen?(n, false) } }
    @objc private func openItemInNewTab(_ s: NSMenuItem) { if let id = s.representedObject as? UUID, let n = store.node(id) { onOpen?(n, true) } }
    @objc private func delete(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { store.remove(id) } }
    @objc private func rename(_ s: NSMenuItem) {
        guard let id = s.representedObject as? UUID, let n = store.node(id), let name = prompt("Rename", initial: n.displayTitle) else { return }
        store.rename(id, to: name)
    }
    @objc private func newFolderIn(_ s: NSMenuItem) {
        guard let id = s.representedObject as? UUID, let name = prompt("New Folder", initial: "New Folder") else { return }
        expanded.insert(id)
        store.addFolder(name, in: id)
    }
    @objc private func newFolderClicked() {
        guard let name = prompt("New Folder", initial: "New Folder") else { return }
        store.addFolder(name, in: store.other.id)
    }
    @objc private func importClicked(_ sender: NSButton) {
        importMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func prompt(_ title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: tr("OK")); alert.addButton(withTitle: tr("Cancel"))
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let t = field.stringValue.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

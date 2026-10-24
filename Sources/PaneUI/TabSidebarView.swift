import AppKit
import PaneModel

@MainActor
protocol TabCommands: AnyObject {
    func newTab(inGroup: UUID?)
    func activate(_ id: UUID)
    func close(_ id: UUID)
    func sleep(_ id: UUID)
    func duplicate(_ id: UUID)
    func closeOthers(_ id: UUID)
    func copyLink(_ id: UUID)
    func toggleMute(_ id: UUID)
    func openURL(_ url: String, inGroup: UUID?)
}

final class SidebarNode: NSObject {
    enum Kind: Equatable { case tab(UUID), group(UUID), sleeping }
    let kind: Kind
    init(_ k: Kind) { kind = k }
}

@MainActor
final class TabSidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let store: TabStore
    weak var commands: TabCommands?
    var favicon: (UUID) -> NSImage? = { _ in nil }
    var isLoading: (UUID) -> Bool = { _ in false }
    var isAudible: (UUID) -> Bool = { _ in false }
    var isMuted: (UUID) -> Bool = { _ in false }

    private let pinned = PinnedGridView()
    private let outline = ContextOutlineView()
    private var tabNodes: [UUID: SidebarNode] = [:]
    private var groupNodes: [UUID: SidebarNode] = [:]
    private let sleepingNode = SidebarNode(.sleeping)
    private var sleepingExpanded = false
    private var syncing = false
    private var animatingUntil = Date.distantPast
    private var reloadPending = false
    private var knownTabs: Set<UUID> = []

    /// Set when the window supports workspaces (not private windows).
    var workspaces: WorkspaceStore? { didSet { refreshWorkspace() } }
    var onSwitchWorkspace: ((UUID) -> Void)?
    private var workspaceButton: PillButton!

    init(store: TabStore) {
        self.store = store
        super.init(frame: .zero)
        build()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tabs"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.indentationPerLevel = 10
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.rowHeight = 32
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false
        outline.allowsEmptySelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([.paneTab, .URL, .string])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .gap
        outline.setAccessibilityLabel(tr("Tabs"))
        outline.menuProvider = { [weak self] row in self?.menu(forRow: row) }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        pinned.translatesAutoresizingMaskIntoConstraints = false
        pinned.onSelect = { [weak self] id in self?.commands?.activate(id) }
        pinned.onDrop = { [weak self] id, before in self?.store.pin(id, before: before) }
        pinned.menuProvider = { [weak self] id in self?.tabMenu(for: id) }

        let newTab = PillButton(title: { let t = tr("New Tab·short"); return t.hasSuffix("·short") ? tr("New Tab") : t }(), symbol: "plus", target: self, action: #selector(newTabClicked))
        newTab.toolTip = ShortcutCatalog.hint("New Tab", "New Tab")
        let newGroup = PillButton(title: "", symbol: "folder.badge.plus", target: self, action: #selector(newGroupClicked))
        newGroup.toolTip = ShortcutCatalog.hint("New Group", "New Group")
        newGroup.setAccessibilityLabel(tr("New Group"))
        newGroup.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let row = NSStackView(views: [newTab, newGroup])
        row.spacing = 8
        row.distribution = .fill
        workspaceButton = PillButton(title: "", symbol: "square.stack.3d.up", target: self, action: #selector(workspaceClicked(_:)))
        workspaceButton.isHidden = true
        let bottom = NSStackView(views: [workspaceButton, row])
        bottom.orientation = .vertical
        bottom.spacing = 8
        bottom.alignment = .leading
        workspaceButton.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        row.widthAnchor.constraint(equalTo: bottom.widthAnchor).isActive = true
        bottom.translatesAutoresizingMaskIntoConstraints = false
        newTab.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        addSubview(pinned); addSubview(scroll); addSubview(bottom)
        NSLayoutConstraint.activate([
            pinned.topAnchor.constraint(equalTo: topAnchor, constant: 44),
            pinned.leadingAnchor.constraint(equalTo: leadingAnchor),
            pinned.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: pinned.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setAccessibilityLabel(tr("Tab sidebar"))
    }

    // MARK: Sync with model

    /// Rebuilds the list. Calls are coalesced and held back while a disclosure animation runs:
    /// reloading an NSOutlineView mid-animation leaves blank or overlapping rows.
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

    private func performReload() {
        syncing = true
        defer { syncing = false }
        // Keep node identity stable so expansion state survives a reload.
        let liveTabs = Set(store.tabs.map(\.id)), liveGroups = Set(store.groups.map(\.id))
        tabNodes = tabNodes.filter { liveTabs.contains($0.key) }
        groupNodes = groupNodes.filter { liveGroups.contains($0.key) }
        for t in store.tabs where tabNodes[t.id] == nil { tabNodes[t.id] = SidebarNode(.tab(t.id)) }
        for g in store.groups where groupNodes[g.id] == nil { groupNodes[g.id] = SidebarNode(.group(g.id)) }

        pinned.setEntries(pinnedEntries())
        outline.reloadData()
        for g in store.groups {
            if let n = groupNodes[g.id] { if g.isCollapsed == outline.isItemExpanded(n) { g.isCollapsed ? outline.collapseItem(n) : outline.expandItem(n) } }
        }
        if sleepingExpanded != outline.isItemExpanded(sleepingNode) { sleepingExpanded ? outline.expandItem(sleepingNode) : outline.collapseItem(sleepingNode) }
        selectActive()

        // New tabs ease in instead of popping into the list.
        let now = Set(store.tabs.map(\.id))
        let fresh = knownTabs.isEmpty ? [] : now.subtracting(knownTabs)
        knownTabs = now
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for id in fresh {
                guard let node = tabNodes[id] else { continue }
                let row = outline.row(forItem: node)
                guard row >= 0, let view = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
                view.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                    view.animator().alphaValue = 1
                }
            }
        }
    }

    private func pinnedEntries() -> [PinnedEntry] {
        store.pinned.map { PinnedEntry(id: $0.id, title: $0.displayTitle, icon: favicon($0.id), isActive: $0.id == store.activeTabID) }
    }

    /// Fades a tab's row out, then calls `completion` (immediately when there is nothing on screen to fade).
    func fadeOut(_ id: UUID, completion: @escaping @MainActor () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let node = tabNodes[id] else { completion(); return }
        let row = outline.row(forItem: node)
        guard row >= 0, let view = outline.rowView(atRow: row, makeIfNecessary: false) else { completion(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            view.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { completion() } })
    }

    /// Updates one tab's row in place (title, icon, spinner, audio) without rebuilding the list,
    /// so hover, scroll position and drags are left alone.
    func refreshTab(_ id: UUID) {
        guard let t = store.tab(id) else { return }
        if t.isPinned { pinned.setEntries(pinnedEntries()); return }
        guard let node = tabNodes[id] else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView else { return }
        cell.configure(t, icon: favicon(id), dimmed: t.isSleeping, active: id == store.activeTabID, loading: isLoading(id), audible: isAudible(id), muted: isMuted(id))
    }

    private func selectActive() {
        guard let id = store.activeTabID, let n = tabNodes[id] else { outline.deselectAll(nil); return }
        let row = outline.row(forItem: n)
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row) }
        else { outline.deselectAll(nil) }
    }

    // MARK: Data source

    private func children(of node: SidebarNode?) -> [SidebarNode] {
        guard let node else {
            var out = store.ungrouped.compactMap { tabNodes[$0.id] }
            out += store.groups.compactMap { groupNodes[$0.id] }
            if !store.sleeping.isEmpty { out.append(sleepingNode) }
            return out
        }
        switch node.kind {
        case .group(let g): return store.tabs(in: g).compactMap { tabNodes[$0.id] }
        case .sleeping: return store.sleeping.compactMap { tabNodes[$0.id] }
        case .tab: return []
        }
    }

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item as? SidebarNode).count }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item as? SidebarNode)[index] }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if case .tab = (item as! SidebarNode).kind { return false }
        return true
    }

    // MARK: Delegate

    func outlineView(_ ov: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard case .tab = (item as! SidebarNode).kind else { return nil }
        return PaneRowView()
    }

    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! SidebarNode
        switch node.kind {
        case .tab(let id):
            guard let t = store.tab(id) else { return nil }
            let id2 = NSUserInterfaceItemIdentifier("tab")
            let cell = (ov.makeView(withIdentifier: id2, owner: self) as? TabCellView) ?? { let c = TabCellView(); c.identifier = id2; return c }()
            cell.configure(t, icon: favicon(id), dimmed: t.isSleeping, active: id == store.activeTabID, loading: isLoading(id), audible: isAudible(id), muted: isMuted(id))
            cell.onClose = { [weak self] id in self?.commands?.close(id) }
            cell.onToggleMute = { [weak self] id in self?.commands?.toggleMute(id) }
            return cell
        case .group(let gid):
            guard let g = store.group(gid) else { return nil }
            let id2 = NSUserInterfaceItemIdentifier("group")
            let cell = (ov.makeView(withIdentifier: id2, owner: self) as? GroupCellView) ?? { let c = GroupCellView(); c.identifier = id2; return c }()
            cell.configure(name: g.name, color: GroupPalette.color(g.colorIndex), count: store.tabs(in: gid).count)
            return cell
        case .sleeping:
            let id2 = NSUserInterfaceItemIdentifier("sleeping")
            let cell = (ov.makeView(withIdentifier: id2, owner: self) as? GroupCellView) ?? { let c = GroupCellView(); c.identifier = id2; return c }()
            cell.configure(name: tr("Sleeping"), color: nil, symbol: "moon.zzz.fill", count: store.sleeping.count)
            return cell
        }
    }

    func outlineView(_ ov: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if case .tab = (item as! SidebarNode).kind { return 32 }
        return 26
    }

    func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if case .tab = (item as! SidebarNode).kind { return true }
        return false
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        guard !syncing, outline.selectedRow >= 0,
              let node = outline.item(atRow: outline.selectedRow) as? SidebarNode,
              case .tab(let id) = node.kind, id != store.activeTabID else { return }
        commands?.activate(id)
    }

    func outlineViewItemDidExpand(_ n: Notification) { expansionChanged(n, expanded: true) }
    func outlineViewItemDidCollapse(_ n: Notification) { expansionChanged(n, expanded: false) }
    private func expansionChanged(_ n: Notification, expanded: Bool) {
        guard !syncing, let node = n.userInfo?["NSObject"] as? SidebarNode else { return }
        switch node.kind {
        case .group(let id): store.setGroupCollapsed(id, !expanded)
        case .sleeping: sleepingExpanded = expanded
        case .tab: break
        }
    }

    // MARK: Drag & drop

    func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard case .tab(let id) = (item as! SidebarNode).kind else { return nil }
        let p = NSPasteboardItem()
        p.setString(id.uuidString, forType: .paneTab)
        return p
    }

    private func draggedID(_ info: NSDraggingInfo) -> UUID? {
        info.draggingPasteboard.string(forType: .paneTab).flatMap(UUID.init(uuidString:))
    }

    /// A web address dragged in from elsewhere (a link, the address bar, another app).
    private func droppedURL(_ info: NSDraggingInfo) -> String? {
        let pb = info.draggingPasteboard
        if let u = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first, ["http", "https"].contains(u.scheme ?? "") { return u.absoluteString }
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("http://") || s.hasPrefix("https://"), !s.contains(" ") { return s }
        return nil
    }

    func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if draggedID(info) == nil, droppedURL(info) != nil {
            if let node = item as? SidebarNode, case .group = node.kind { ov.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex) }
            else { ov.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex) }
            return .copy
        }
        guard draggedID(info) != nil else { return [] }
        guard let node = item as? SidebarNode else {
            let n = store.ungrouped.count
            if index == NSOutlineViewDropOnItemIndex || index > n { ov.setDropItem(nil, dropChildIndex: n) }
            return .move
        }
        switch node.kind {
        case .group: return .move
        case .sleeping:
            ov.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        case .tab:
            let parent = ov.parent(forItem: node)
            ov.setDropItem(parent, dropChildIndex: ov.childIndex(forItem: node))
            return .move
        }
    }

    func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if draggedID(info) == nil, let url = droppedURL(info) {
            var group: UUID?
            if let node = item as? SidebarNode, case .group(let g) = node.kind { group = g }
            commands?.openURL(url, inGroup: group)
            return true
        }
        guard let id = draggedID(info) else { return false }
        guard let node = item as? SidebarNode else {
            let list = store.ungrouped
            store.move(id, toGroup: nil, before: index >= 0 && index < list.count ? list[index].id : nil)
            return true
        }
        switch node.kind {
        case .group(let gid):
            let list = store.tabs(in: gid)
            store.move(id, toGroup: gid, before: index >= 0 && index < list.count ? list[index].id : nil)
            return true
        case .sleeping:
            commands?.sleep(id)
            return true
        case .tab: return false
        }
    }

    // MARK: Menus

    private func menu(forRow row: Int) -> NSMenu? {
        guard let node = outline.item(atRow: row) as? SidebarNode else { return nil }
        switch node.kind {
        case .tab(let id): return tabMenu(for: id)
        case .group(let gid): return groupMenu(for: gid)
        case .sleeping: return nil
        }
    }

    private func item(_ title: String, _ action: Selector, _ obj: Any? = nil, state: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: tr(title), action: action, keyEquivalent: "")
        i.target = self; i.representedObject = obj; i.state = state ? .on : .off
        return i
    }

    private func tabMenu(for id: UUID) -> NSMenu? {
        guard let t = store.tab(id) else { return nil }
        let m = NSMenu()
        m.addItem(item(t.isPinned ? "Unpin Tab" : "Pin Tab", #selector(togglePin(_:)), id))
        if !t.isPinned && !t.isSleeping && id != store.activeTabID { m.addItem(item(tr("Put to Sleep"), #selector(sleepTab(_:)), id)) }
        if !t.url.isEmpty {
            m.addItem(item(tr("Duplicate Tab"), #selector(duplicateTab(_:)), id))
            m.addItem(item(tr("Copy Link"), #selector(copyTabLink(_:)), id))
            m.addItem(item(tr("Copy as Markdown Link"), #selector(copyMarkdownLink(_:)), id))
        }
        if !t.isPinned {
            let moveItem = NSMenuItem(title: tr("Move to Group"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(item(tr("No Group"), #selector(moveToGroup(_:)), [id, UUID?.none as Any], state: t.groupID == nil))
            for g in store.groups { sub.addItem(item(g.name, #selector(moveToGroup(_:)), [id, g.id], state: t.groupID == g.id)) }
            sub.addItem(.separator())
            sub.addItem(item(tr("New Group…"), #selector(newGroupWithTab(_:)), id))
            moveItem.submenu = sub
            m.addItem(moveItem)
        }
        m.addItem(.separator())
        m.addItem(item(tr("Close Tab"), #selector(closeTab(_:)), id))
        if store.tabs.contains(where: { $0.id != id && !$0.isPinned }) { m.addItem(item(tr("Close Other Tabs"), #selector(closeOtherTabs(_:)), id)) }
        return m
    }

    private func groupMenu(for gid: UUID) -> NSMenu? {
        guard let g = store.group(gid) else { return nil }
        let m = NSMenu()
        m.addItem(item(tr("New Tab in Group"), #selector(newTabInGroup(_:)), gid))
        m.addItem(item(tr("Rename…"), #selector(renameGroup(_:)), gid))
        let colorItem = NSMenuItem(title: tr("Color"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, c) in GroupPalette.colors.enumerated() {
            let mi = item(c.name, #selector(setColor(_:)), [gid, i], state: g.colorIndex == i)
            mi.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [c.color]))
            sub.addItem(mi)
        }
        colorItem.submenu = sub
        m.addItem(colorItem)
        m.addItem(.separator())
        m.addItem(item(tr("Close All Tabs in Group"), #selector(closeGroupTabs(_:)), gid))
        m.addItem(item(tr("Delete Group (Keep Tabs)"), #selector(deleteGroup(_:)), gid))
        return m
    }

    @objc private func togglePin(_ s: NSMenuItem) {
        guard let id = s.representedObject as? UUID, let t = store.tab(id) else { return }
        t.isPinned ? store.unpin(id) : store.pin(id)
    }
    @objc private func sleepTab(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { commands?.sleep(id) } }
    @objc private func duplicateTab(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { commands?.duplicate(id) } }
    @objc private func copyTabLink(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { commands?.copyLink(id) } }
    @objc private func copyMarkdownLink(_ s: NSMenuItem) {
        guard let id = s.representedObject as? UUID, let t = store.tab(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[\(t.displayTitle)](\(t.url))", forType: .string)
    }
    @objc private func closeOtherTabs(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { commands?.closeOthers(id) } }
    @objc private func closeTab(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { commands?.close(id) } }
    @objc private func moveToGroup(_ s: NSMenuItem) {
        guard let a = s.representedObject as? [Any], let id = a[0] as? UUID else { return }
        store.move(id, toGroup: a[1] as? UUID)
    }
    @objc private func newGroupWithTab(_ s: NSMenuItem) {
        guard let id = s.representedObject as? UUID, let name = promptName(title: tr("New Group"), initial: tr("New Group")) else { return }
        let g = store.createGroup(name: name, colorIndex: store.groups.count)
        store.move(id, toGroup: g)
    }
    @objc private func newTabInGroup(_ s: NSMenuItem) { if let g = s.representedObject as? UUID { commands?.newTab(inGroup: g) } }
    @objc private func renameGroup(_ s: NSMenuItem) {
        guard let gid = s.representedObject as? UUID, let g = store.group(gid),
              let name = promptName(title: "Rename Group", initial: g.name) else { return }
        store.renameGroup(gid, to: name)
    }
    @objc private func setColor(_ s: NSMenuItem) {
        guard let a = s.representedObject as? [Any], let gid = a[0] as? UUID, let i = a[1] as? Int else { return }
        store.setGroupColor(gid, colorIndex: i)
    }
    @objc private func closeGroupTabs(_ s: NSMenuItem) {
        guard let gid = s.representedObject as? UUID else { return }
        for t in store.tabs where t.groupID == gid { commands?.close(t.id) }
    }
    @objc private func deleteGroup(_ s: NSMenuItem) { if let gid = s.representedObject as? UUID { store.deleteGroup(gid) } }

    @objc private func newTabClicked() { commands?.newTab(inGroup: nil) }
    @objc private func newGroupClicked() { createGroupInteractively() }

    func createGroupInteractively() {
        guard let name = promptName(title: tr("New Group"), initial: tr("New Group")) else { return }
        store.createGroup(name: name, colorIndex: store.groups.count)
    }

    // MARK: Workspaces

    func refreshWorkspace() {
        guard let ws = workspaces, workspaceButton != nil else { return }
        workspaceButton.isHidden = false
        workspaceButton.title = tr(ws.active.name)
        workspaceButton.imagePosition = .imageLeading
        workspaceButton.imageHugsTitle = true
        workspaceButton.toolTip = tr("Workspaces")
        workspaceButton.setAccessibilityLabel(String(localized: "Workspace \(tr(ws.active.name))"))
    }

    @objc private func workspaceClicked(_ sender: NSButton) {
        guard let ws = workspaces else { return }
        let m = NSMenu()
        for w in ws.workspaces {
            let it = NSMenuItem(title: tr(w.name), action: #selector(pickWorkspace(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = w.id; it.state = w.id == ws.activeID ? .on : .off
            it.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [GroupPalette.color(w.colorIndex)]))
            m.addItem(it)
        }
        m.addItem(.separator())
        let add = NSMenuItem(title: tr("New Workspace…"), action: #selector(newWorkspace(_:)), keyEquivalent: ""); add.target = self; m.addItem(add)
        let ren = NSMenuItem(title: tr("Rename Workspace…"), action: #selector(renameWorkspace(_:)), keyEquivalent: ""); ren.target = self; m.addItem(ren)
        if ws.activeID != WorkspaceStore.mainID {
            let del = NSMenuItem(title: tr("Delete Workspace…"), action: #selector(deleteWorkspace(_:)), keyEquivalent: ""); del.target = self; m.addItem(del)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
    @objc private func pickWorkspace(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { onSwitchWorkspace?(id) } }
    @objc private func newWorkspace(_ s: Any?) {
        guard let ws = workspaces, let name = promptName(title: tr("New Workspace"), initial: ""), let w = ws.add(name: name) else { NSSound.beep(); return }
        onSwitchWorkspace?(w.id)
    }
    @objc private func renameWorkspace(_ s: Any?) {
        guard let ws = workspaces, let name = promptName(title: tr("Rename Workspace"), initial: tr(ws.active.name)) else { return }
        ws.rename(ws.activeID, to: name); refreshWorkspace()
    }
    @objc private func deleteWorkspace(_ s: Any?) {
        guard let ws = workspaces, ws.activeID != WorkspaceStore.mainID else { return }
        let alert = NSAlert()
        alert.messageText = tr("Delete this workspace?")
        alert.informativeText = tr("Its tabs and groups are closed. Bookmarks and history are kept.")
        alert.addButton(withTitle: tr("Delete Workspace")); alert.addButton(withTitle: tr("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let doomed = ws.activeID
        onSwitchWorkspace?(WorkspaceStore.mainID)
        ws.remove(doomed); refreshWorkspace()
    }

    private func promptName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: tr("OK"))
        alert.addButton(withTitle: tr("Cancel"))
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

import AppKit
import PaneModel

enum PaletteChoice {
    case item(SearchItem)
    case web(String)  // raw query: go to it if it's an address, otherwise search
}

private enum PaletteRow {
    case header(String)
    case hit(SearchHit)
    case web(String)
}

@MainActor
final class PaletteRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        Style.fill(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 11, yRadius: 11).fill()
    }
}

@MainActor
final class PaletteCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private let sparkle = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 5
        icon.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        kindLabel.font = .systemFont(ofSize: 11)
        kindLabel.textColor = .secondaryLabelColor
        sparkle.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Found by meaning")
        sparkle.contentTintColor = .tertiaryLabelColor
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text, sparkle, kindLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        text.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        text.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            sparkle.widthAnchor.constraint(equalToConstant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(title t: String, subtitle s: String, tag g: String, icon image: NSImage?, symbol: String?, meaning: Bool) {
        title.stringValue = t
        subtitle.stringValue = s
        kindLabel.stringValue = g
        sparkle.isHidden = !meaning
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
        } else {
            icon.image = tabIcon(image)
            icon.contentTintColor = image == nil ? .secondaryLabelColor : nil
        }
        setAccessibilityLabel(tr("\(t), \(g)"))
    }
}

@MainActor
final class PaletteHeaderCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func configure(_ s: String) { label.stringValue = s.uppercased() }
}

/// ⌘K overlay: one field that searches open tabs, bookmarks and history by words and by meaning.
@MainActor
final class CommandPaletteView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let provider: SearchProvider
    private let items: () -> [SearchItem]
    private let icon: (String) -> NSImage?
    private let onChoose: (PaletteChoice, _ newTab: Bool) -> Void
    private let onClose: () -> Void
    private let engineName: () -> String

    private let card: NSView
    private let field = NSTextField()
    private let table = NSTableView()
    private let divider = NSBox()
    private let scroll = NSScrollView()
    private var rows: [PaletteRow] = []
    private var cardHeight: NSLayoutConstraint!
    private var cardTop: NSLayoutConstraint!
    private var semanticTask: Task<Void, Never>?
    private var generation = 0
    private var snapshot: [SearchItem] = []

    private static let rowHeight: CGFloat = 46, headerHeight: CGFloat = 28, fieldHeight: CGFloat = 60

    init(provider: SearchProvider, items: @escaping () -> [SearchItem], icon: @escaping (String) -> NSImage?,
         onChoose: @escaping (PaletteChoice, Bool) -> Void, onClose: @escaping () -> Void,
         engineName: @escaping () -> String = { "the web" }) {
        self.engineName = engineName
        self.provider = provider; self.items = items; self.icon = icon; self.onChoose = onChoose; self.onClose = onClose
        let content = NSView()
        card = Glass.surface(content: content, cornerRadius: 24)
        super.init(frame: .zero)
        wantsLayer = true
        buildCard(content)
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("Search tabs, bookmarks and history"))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func buildCard(_ content: NSView) {
        field.placeholderString = tr("Search tabs, bookmarks and history")
        field.font = .systemFont(ofSize: 19, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel(tr("Search"))
        field.translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        glyph.contentTintColor = .secondaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityLabel(tr("Results"))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(glyph); content.addSubview(field); content.addSubview(divider); content.addSubview(scroll)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            glyph.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight / 2),
            glyph.widthAnchor.constraint(equalToConstant: 18), glyph.heightAnchor.constraint(equalToConstant: 18),
            field.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            field.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor), divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])

        addSubview(card)
        cardHeight = card.heightAnchor.constraint(equalToConstant: Self.fieldHeight)
        cardTop = card.topAnchor.constraint(equalTo: topAnchor, constant: 90)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: 660),
            cardTop, cardHeight,
        ])
    }

    // MARK: Presentation

    func debugSetQuery(_ q: String) { field.stringValue = q; refresh(query: q) }

    func present(in parent: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor), trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            topAnchor.constraint(equalTo: parent.topAnchor), bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
        snapshot = items()
        parent.layoutSubtreeIfNeeded()
        refresh(query: "")
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0).cgColor
        card.alphaValue = 0
        cardTop.constant = 70
        layoutSubtreeIfNeeded()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0.01 : 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            ctx.allowsImplicitAnimation = true
            card.animator().alphaValue = 1
            cardTop.animator().constant = 90
            layer?.backgroundColor = NSColor.black.withAlphaComponent(Style.highContrast ? 0.35 : 0.18).cgColor
        }
        window?.makeFirstResponder(field)
    }

    func dismiss() {
        semanticTask?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            card.animator().alphaValue = 0
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0).cgColor
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        })
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit == nil ? self : hit
    }
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onClose() }
    }

    // MARK: Results

    func controlTextDidChange(_ obj: Notification) { refresh(query: field.stringValue) }

    private func refresh(query: String) {
        semanticTask?.cancel()
        generation += 1
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            var out: [PaletteRow] = []
            let tabs = snapshot.filter { $0.kind == .tab }.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }.prefix(6)
            let recent = snapshot.filter { $0.kind == .history }.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            let openURLs = Set(tabs.map { normalizedURL($0.url) })
            if !tabs.isEmpty { out.append(.header("Open Tabs")); out += tabs.map { .hit(SearchHit(item: $0, score: 0)) } }
            let rec = recent.filter { !openURLs.contains(normalizedURL($0.url)) }.prefix(5)
            if !rec.isEmpty { out.append(.header("Recent")); out += rec.map { .hit(SearchHit(item: $0, score: 0)) } }
            apply(out)
            return
        }
        let keyword = provider.keywordSearch(q, in: snapshot, limit: 8)
        apply(keyword.map { .hit($0) } + [.web(q)])

        let gen = generation, items = snapshot, p = provider
        semanticTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)  // let typing settle
            if Task.isCancelled { return }
            let semantic = await Task.detached(priority: .userInitiated) { await p.semanticSearch(q, in: items, limit: 5) }.value
            if Task.isCancelled || semantic.isEmpty { return }
            await MainActor.run {
                guard let self, self.generation == gen else { return }
                let have = Set(keyword.map { normalizedURL($0.item.url) })
                let extra = semantic.filter { !have.contains(normalizedURL($0.item.url)) }.prefix(max(0, 8 - keyword.count))
                guard !extra.isEmpty else { return }
                let keepSelection = self.table.selectedRow
                self.apply(keyword.map { .hit($0) } + extra.map { .hit($0) } + [.web(q)], selecting: keepSelection)
            }
        }
    }

    private func apply(_ new: [PaletteRow], selecting: Int? = nil) {
        rows = new
        table.reloadData()
        let first = selecting.flatMap { $0 >= 0 && $0 < rows.count ? $0 : nil } ?? rows.firstIndex { if case .header = $0 { return false }; return true }
        if let first { table.selectRowIndexes([first], byExtendingSelection: false); table.scrollRowToVisible(first) }
        let h = rows.reduce(CGFloat(0)) { $0 + height(of: $1) }
        let target = Self.fieldHeight + 12 + min(h, 420)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            cardHeight.animator().constant = target
        }
    }

    private func height(of row: PaletteRow) -> CGFloat { if case .header = row { return Self.headerHeight }; return Self.rowHeight }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat { height(of: rows[row]) }
    func tableView(_ tv: NSTableView, shouldSelectRow row: Int) -> Bool { if case .header = rows[row] { return false }; return true }
    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let s):
            let id = NSUserInterfaceItemIdentifier("h")
            let c = (tv.makeView(withIdentifier: id, owner: self) as? PaletteHeaderCell) ?? { let c = PaletteHeaderCell(); c.identifier = id; return c }()
            c.configure(s)
            return c
        case .hit(let h):
            let id = NSUserInterfaceItemIdentifier("r")
            let c = (tv.makeView(withIdentifier: id, owner: self) as? PaletteCell) ?? { let c = PaletteCell(); c.identifier = id; return c }()
            let tag: String = { switch h.item.kind { case .tab: "Tab"; case .bookmark: "Bookmark"; case .history: "History" } }()
            c.configure(title: h.item.title.isEmpty ? h.item.host : h.item.title, subtitle: h.item.host,
                        tag: tag, icon: icon(h.item.url), symbol: nil, meaning: h.viaMeaning)
            return c
        case .web(let q):
            let id = NSUserInterfaceItemIdentifier("r")
            let c = (tv.makeView(withIdentifier: id, owner: self) as? PaletteCell) ?? { let c = PaletteCell(); c.identifier = id; return c }()
            let isAddress = AddressInput.looksLikeAddress(q)
            c.configure(title: isAddress ? "Go to \(q)" : "Search the web for “\(q)”", subtitle: isAddress ? "Open address" : engineName(),
                        tag: "", icon: nil, symbol: isAddress ? "arrow.right.circle" : "globe", meaning: false)
            return c
        }
    }

    @objc private func rowClicked() { choose(row: table.clickedRow, newTab: NSEvent.modifierFlags.contains(.command)) }

    private func choose(row: Int, newTab: Bool) {
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case .header: return
        case .hit(let h): onChoose(.item(h.item), newTab)
        case .web(let q): onChoose(.web(q), newTab)
        }
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            choose(row: table.selectedRow, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
            return true
        case #selector(NSResponder.cancelOperation(_:)): onClose(); return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        var i = table.selectedRow + d
        while i >= 0 && i < rows.count { if case .header = rows[i] { i += d } else { break } }
        guard i >= 0, i < rows.count else { return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }
}

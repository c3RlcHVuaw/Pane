import AppKit
import PaneModel

/// The dropdown under the address bar: matching tabs, bookmarks and history, plus "search the web".
@MainActor
final class AddressSuggestionsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Row { case hit(SearchHit), web(String) }

    var onChoose: ((Row) -> Void)?
    var icon: (String) -> NSImage? = { _ in nil }
    var engineName: () -> String = { "the web" }

    private let card: NSView
    private let table = NSTableView()
    private var rows: [Row] = []
    private var height: NSLayoutConstraint!
    private static let rowHeight: CGFloat = 46

    var isVisible: Bool { !isHidden }

    init() {
        let content = NSView()
        card = Glass.surface(content: content, cornerRadius: 18)
        super.init(frame: .zero)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = .zero
        table.rowHeight = Self.rowHeight
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true  // clicking a row must not pull focus out of the address field
        table.setAccessibilityLabel(tr("Suggestions"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 6), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        addSubview(card)
        height = heightAnchor.constraint(equalToConstant: 60)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor), height,
        ])
        isHidden = true
        setAccessibilityRole(.list)
        setAccessibilityLabel(tr("Address suggestions"))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ new: [Row]) {
        rows = new
        table.reloadData()
        table.deselectAll(nil)
        height.constant = CGFloat(rows.count) * Self.rowHeight + 12
        guard !rows.isEmpty else { hide(); return }
        if isHidden {
            alphaValue = 0
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.01 : 0.14
                animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        rows = []
    }

    /// Arrow keys: -1 moves up (past the first row it returns to "what I typed"), +1 moves down.
    func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        var i = table.selectedRow + d
        if i < -1 { i = rows.count - 1 }
        if i >= rows.count { i = -1 }
        if i < 0 { table.deselectAll(nil) } else { table.selectRowIndexes([i], byExtendingSelection: false); table.scrollRowToVisible(i) }
    }

    var chosenRow: Row? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil }

    @objc private func clicked() {
        guard table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        onChoose?(rows[table.clickedRow])
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }
    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("r")
        let c = (tv.makeView(withIdentifier: id, owner: self) as? PaletteCell) ?? { let c = PaletteCell(); c.identifier = id; return c }()
        switch rows[row] {
        case .hit(let h):
            let tag: String = { switch h.item.kind { case .tab: "Switch to Tab"; case .bookmark: "Bookmark"; case .history: "History" } }()
            c.configure(title: h.item.title.isEmpty ? h.item.host : h.item.title, subtitle: h.item.host, tag: tag,
                        icon: icon(h.item.url), symbol: nil, meaning: false)
        case .web(let q):
            let isAddress = AddressInput.looksLikeAddress(q)
            c.configure(title: isAddress ? "Go to \(q)" : "Search \(engineName()) for “\(q)”", subtitle: isAddress ? "Open address" : "Web search",
                        tag: "", icon: nil, symbol: isAddress ? "arrow.right.circle" : "magnifyingglass", meaning: false)
        }
        return c
    }
}

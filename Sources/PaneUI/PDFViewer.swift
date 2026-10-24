import AppKit
import PDFKit
import PaneModel

/// A native PDF reader shown over a tab whose page is a PDF: page thumbnails of PDFKit's quality, text selection,
/// search, zoom and "Save a Copy", all in the style of the rest of the browser.
@MainActor
final class PDFViewerOverlay: NSView, NSSearchFieldDelegate {
    private let pdf = PDFView()
    private let search = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private var matches: [PDFSelection] = []
    private var current = 0
    private let sourceURL: URL
    private let data: Data

    init?(data: Data, sourceURL: URL) {
        guard let doc = PDFDocument(data: data) else { return nil }
        self.data = data; self.sourceURL = sourceURL
        super.init(frame: .zero)
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        pdf.document = doc
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displayBox = .cropBox
        pdf.backgroundColor = .clear
        pdf.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pdf)

        search.placeholderString = tr("Search in PDF")
        search.delegate = self
        search.sendsSearchStringImmediately = false
        search.controlSize = .regular
        search.setAccessibilityLabel(tr("Search in PDF"))
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); count.textColor = .secondaryLabelColor
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
            b.isBordered = false; b.toolTip = tip; b.setAccessibilityLabel(tip); b.contentTintColor = .secondaryLabelColor
            return b
        }
        let row = NSStackView(views: [search, count, button("chevron.up", tr("Previous match"), #selector(prev)), button("chevron.down", tr("Next match"), #selector(next)),
                                      button("minus.magnifyingglass", tr("Zoom Out"), #selector(zoomOut)), button("plus.magnifyingglass", tr("Zoom In"), #selector(zoomIn)),
                                      button("square.and.arrow.down", tr("Save a Copy…"), #selector(save))])
        row.spacing = 8; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let pill = Glass.surface(content: row, cornerRadius: 14)
        addSubview(pill)
        NSLayoutConstraint.activate([
            pdf.leadingAnchor.constraint(equalTo: leadingAnchor), pdf.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdf.topAnchor.constraint(equalTo: topAnchor), pdf.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12), row.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: pill.topAnchor, constant: 7), row.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -7),
            pill.topAnchor.constraint(equalTo: topAnchor, constant: 12), pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
        ])
        setAccessibilityLabel(tr("PDF document"))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    }

    func focusSearch() { window?.makeFirstResponder(search) }

    func controlTextDidEndEditing(_ obj: Notification) {
        let q = search.stringValue
        guard !q.isEmpty, let doc = pdf.document else { matches = []; pdf.highlightedSelections = nil; count.stringValue = ""; return }
        matches = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        matches.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.5) }
        pdf.highlightedSelections = matches
        current = 0
        show()
    }

    private func show() {
        count.stringValue = matches.isEmpty ? tr("No matches") : "\(current + 1)/\(matches.count)"
        guard matches.indices.contains(current) else { return }
        pdf.setCurrentSelection(matches[current], animate: true)
        pdf.go(to: matches[current])
    }
    @objc private func next() { guard !matches.isEmpty else { return }; current = (current + 1) % matches.count; show() }
    @objc private func prev() { guard !matches.isEmpty else { return }; current = (current - 1 + matches.count) % matches.count; show() }
    @objc private func zoomIn() { pdf.autoScales = false; pdf.zoomIn(nil) }
    @objc private func zoomOut() { pdf.autoScales = false; pdf.zoomOut(nil) }
    @objc private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.lastPathComponent.isEmpty ? "document.pdf" : sourceURL.lastPathComponent
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

enum PDFFetcher {
    /// The bytes of the PDF at `url` (a web address or a local file), or nil.
    static func data(for url: URL) async -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url) }
        guard ["http", "https"].contains(url.scheme) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("application/pdf,*/*", forHTTPHeaderField: "Accept")
        guard let (d, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400, d.count < 200_000_000 else { return nil }
        return d.prefix(5) == Data("%PDF-".utf8) ? d : nil
    }
}

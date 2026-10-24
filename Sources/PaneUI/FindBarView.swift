import AppKit
import PaneModel

/// ⌘F bar: a small glass capsule in the page's top-right corner.
@MainActor
final class FindBarView: NSView, NSTextFieldDelegate {
    var onQuery: ((_ text: String, _ forward: Bool, _ next: Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let card: NSView
    private var lastText = ""

    init() {
        let content = NSView()
        card = Glass.surface(content: content, cornerRadius: 19)
        super.init(frame: .zero)

        let glyph = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        glyph.contentTintColor = .secondaryLabelColor
        field.placeholderString = tr("Find in page")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel(tr("Find in page"))
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right

        func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action)
            b.isBordered = false
            b.contentTintColor = .labelColor
            b.toolTip = label
            b.setAccessibilityLabel(label)
            return b
        }
        let prev = button("chevron.up", "Previous match  ⇧⌘G", #selector(previous))
        let next = button("chevron.down", "Next match  ⌘G", #selector(nextMatch))
        let done = button("xmark.circle.fill", "Close  esc", #selector(close))
        done.contentTintColor = .tertiaryLabelColor

        let row = NSStackView(views: [glyph, field, count, prev, next, done])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        field.translatesAutoresizingMaskIntoConstraints = false
        count.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 170),
            count.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 38),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(tr("Find in page"))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func attach(to parent: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parent.topAnchor, constant: 12),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16),
        ])
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.01 : 0.18
            animator().alphaValue = 1
        }
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func bringToFront() { superview?.addSubview(self, positioned: .above, relativeTo: nil) }

    func setResult(count n: Int, active: Int) {
        if field.stringValue.isEmpty { count.stringValue = ""; return }
        count.stringValue = n == 0 ? "No matches" : "\(active) of \(n)"
        count.textColor = n == 0 ? .systemRed : .secondaryLabelColor
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.removeFromSuperview() } })
    }

    // MARK: Actions

    func controlTextDidChange(_ obj: Notification) {
        lastText = field.stringValue
        if lastText.isEmpty { count.stringValue = "" }
        onQuery?(lastText, true, false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            let back = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onQuery?(field.stringValue, !back, true)
            return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }

    @objc func nextMatch() { onQuery?(field.stringValue, true, true) }
    @objc func previous() { onQuery?(field.stringValue, false, true) }
    @objc private func close() { onClose?() }
}

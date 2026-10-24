import AppKit

/// Walks a window's accessibility tree and lists interactive elements a screen reader couldn't name.
/// Run with PANE_AUDIT_AX=<file> (see main.swift); the same tree is what Accessibility Inspector shows.
@MainActor
public enum AccessibilityAudit {
    private static let interactive: Set<NSAccessibility.Role> = [
        .button, .textField, .textArea, .checkBox, .radioButton, .popUpButton, .menuButton, .slider, .link, .comboBox, .menuItem,
    ]

    public struct Report {
        public var inspected = 0
        var visited = Set<ObjectIdentifier>()
        public var unlabeled: [String] = []
        public var text: String {
            "inspected \(inspected) elements; \(unlabeled.count) interactive without a name\n" + unlabeled.joined(separator: "\n")
        }
    }

    public static func audit(_ window: NSWindow) -> Report {
        var report = Report()
        if let content = window.contentView { walk(content, path: "window", depth: 0, into: &report) }
        return report
    }

    private static func walk(_ element: NSAccessibilityProtocol, path: String, depth: Int, into r: inout Report) {
        guard depth < 40 else { return }
        if let o = element as? AnyObject, !r.visited.insert(ObjectIdentifier(o)).inserted { return }  // reached twice via different parents
        r.inspected += 1
        let role = element.accessibilityRole()
        if role == .scrollBar { return }  // the system names these
        let name = [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityHelp()]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let valueText = (element.accessibilityValue() as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let role, interactive.contains(role), name == nil, !(role == .textField && valueText != nil) {
            let frame = element.accessibilityFrame()
            let parent = path.split(separator: "/").suffix(3).joined(separator: "/").replacingOccurrences(of: "Unknown", with: "?")
            r.unlabeled.append("  \(role.rawValue) \(String(describing: type(of: element))) \(Int(frame.width))x\(Int(frame.height)) value=\(valueText ?? "-") in …/\(parent)")
        }
        let here = path + "/" + (role?.rawValue.replacingOccurrences(of: "AX", with: "") ?? "?")
        // Visible subviews first (glass containers don't list their content as accessibility children),
        // then anything exposed only through accessibility, such as the insides of SwiftUI views.
        var seen = Set<ObjectIdentifier>()
        var children: [NSAccessibilityProtocol] = []
        // SwiftUI hosting views publish their own accessibility elements; their raw AppKit subviews are
        // implementation details an assistive app never sees, so don't judge those.
        let isHosting = (element as? NSView).map { String(describing: type(of: $0)).contains("HostingView") } ?? false
        if let view = element as? NSView, !isHosting {
            for v in view.subviews where !v.isHidden && v.alphaValue > 0 { seen.insert(ObjectIdentifier(v)); children.append(v) }
        }
        for child in element.accessibilityChildren() ?? [] {
            guard let c = child as? NSAccessibilityProtocol, let o = c as? AnyObject, seen.insert(ObjectIdentifier(o)).inserted else { continue }
            children.append(c)
        }
        for c in children { walk(c, path: here, depth: depth + 1, into: &r) }
    }
}

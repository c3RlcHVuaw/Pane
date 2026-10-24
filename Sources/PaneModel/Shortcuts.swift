import Foundation

public struct ShortcutItem: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let keys: String
}

public struct ShortcutSection: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public let title: String
    public let symbol: String
    public let items: [ShortcutItem]
}

/// One list that Settings, the ⌘/ overlay and the toolbar tooltips all read from.
public enum ShortcutCatalog {
    public static let sections: [ShortcutSection] = [
        ShortcutSection(title: "Tabs", symbol: "square.stack", items: [
            ShortcutItem(name: "New Tab", keys: "⌘T"),
            ShortcutItem(name: "Close Tab", keys: "⌘W"),
            ShortcutItem(name: "Reopen Closed Tab", keys: "⇧⌘T"),
            ShortcutItem(name: "Next Tab", keys: "⇧⌘]"),
            ShortcutItem(name: "Previous Tab", keys: "⇧⌘["),
            ShortcutItem(name: "Jump to Tab 1–8", keys: "⌘1–8"),
            ShortcutItem(name: "Last Tab", keys: "⌘9"),
            ShortcutItem(name: "Pin / Unpin Tab", keys: "⇧⌘P"),
            ShortcutItem(name: "Put Tab to Sleep", keys: "⌥⌘Z"),
            ShortcutItem(name: "New Group", keys: "⌥⌘N"),
        ]),
        ShortcutSection(title: "Navigation", symbol: "arrow.left.arrow.right", items: [
            ShortcutItem(name: "Search Tabs, Bookmarks & History", keys: "⌘K"),
            ShortcutItem(name: "Open Location", keys: "⌘L"),
            ShortcutItem(name: "Open File", keys: "⌘O"),
            ShortcutItem(name: "Save Page As", keys: "⌘S"),
            ShortcutItem(name: "Fill Saved Login", keys: "⌥⌘L"),
            ShortcutItem(name: "Copy Page Address", keys: "⇧⌘C"),
            ShortcutItem(name: "Back", keys: "⌘["),
            ShortcutItem(name: "Forward", keys: "⌘]"),
            ShortcutItem(name: "Reload", keys: "⌘R"),
            ShortcutItem(name: "Find in Page", keys: "⌘F"),
            ShortcutItem(name: "Find Next", keys: "⌘G"),
            ShortcutItem(name: "Find Previous", keys: "⇧⌘G"),
            ShortcutItem(name: "Show Downloads", keys: "⇧⌘J"),
            ShortcutItem(name: "Show All History", keys: "⌘Y"),
            ShortcutItem(name: "Next Workspace", keys: "⌥⌘]"),
            ShortcutItem(name: "Previous Workspace", keys: "⌥⌘["),
            ShortcutItem(name: "Split View", keys: "⌥⌘\\"),
            ShortcutItem(name: "Translate Page", keys: "⌥⌘T"),
            ShortcutItem(name: "Picture in Picture", keys: "⌥⌘P"),
            ShortcutItem(name: "Note for This Page", keys: "⌃⌥⌘N"),
            ShortcutItem(name: "Developer Tools", keys: "⌥⌘I"),
            ShortcutItem(name: "View Source", keys: "⌥⌘U"),
            ShortcutItem(name: "Reader Mode", keys: "⌥⌘R"),
            ShortcutItem(name: "Summarize Page", keys: "⌥⌘S"),
            ShortcutItem(name: "Cancel Address Editing", keys: "esc"),
        ]),
        ShortcutSection(title: "Bookmarks", symbol: "star", items: [
            ShortcutItem(name: "Bookmark This Page", keys: "⌘D"),
            ShortcutItem(name: "Show Bookmarks Bar", keys: "⇧⌘B"),
            ShortcutItem(name: "Show All Bookmarks", keys: "⌥⌘B"),
        ]),
        ShortcutSection(title: "View", symbol: "sidebar.left", items: [
            ShortcutItem(name: "Toggle Sidebar", keys: "⌃⌘S"),
            ShortcutItem(name: "Ask the Assistant", keys: "⇧⌘A"),
            ShortcutItem(name: "Floating Assistant Window", keys: "⌥⇧⌘A"),
            ShortcutItem(name: "Stop the Agent", keys: "⌘."),
            ShortcutItem(name: "Zoom In", keys: "⌘+"),
            ShortcutItem(name: "Zoom Out", keys: "⌘−"),
            ShortcutItem(name: "Actual Size", keys: "⌘0"),
        ]),
        ShortcutSection(title: "App", symbol: "app.badge", items: [
            ShortcutItem(name: "Settings", keys: "⌘,"),
            ShortcutItem(name: "Keyboard Shortcuts", keys: "⌘/"),
            ShortcutItem(name: "New Private Window", keys: "⇧⌘N"),
            ShortcutItem(name: "Print", keys: "⌘P"),
            ShortcutItem(name: "Close Window", keys: "⇧⌘W"),
            ShortcutItem(name: "Quit", keys: "⌘Q"),
        ]),
    ]

    /// "Back  ⌘[" style tooltip text.
    public static func hint(_ title: String, _ name: String) -> String {
        let title = tr(title)
        guard let keys = sections.flatMap(\.items).first(where: { $0.name == name })?.keys else { return title }
        return "\(title)  \(keys)"
    }
}

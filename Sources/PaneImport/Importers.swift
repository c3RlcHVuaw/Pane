import Foundation
import PaneModel

public struct ImportError: Error, Equatable { public var message: String }

private let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")

public func allImporters() -> [BookmarkImporter] {
    [ChromeImporter(), SafariImporter(), ArcImporter(), HTMLImporter()]
}

// MARK: Chrome

public struct ChromeImporter: BookmarkImporter {
    public init() {}
    public var name: String { "Chrome" }
    private var base: URL { support.appendingPathComponent("Google/Chrome") }
    public var openPanelDirectory: URL { base }
    public var openPanelMessage: String { "Choose Chrome's “Bookmarks” file (inside the Default or Profile folder)." }

    public func candidateFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path))?
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted() ?? ["Default"]
        return names.map { base.appendingPathComponent($0).appendingPathComponent("Bookmarks") }
    }

    public func parse(_ data: Data) throws -> [BookmarkNode] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { throw ImportError(message: "Not a Chrome bookmarks file") }
        func node(_ d: [String: Any]) -> BookmarkNode? {
            let title = d["name"] as? String ?? ""
            if d["type"] as? String == "url", let url = d["url"] as? String { return .link(title, url) }
            if d["type"] as? String == "folder" {
                return .folder(title, (d["children"] as? [[String: Any]] ?? []).compactMap(node))
            }
            return nil
        }
        let labels = [("bookmark_bar", "Bookmarks Bar"), ("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks")]
        return labels.compactMap { key, label in
            guard let d = roots[key] as? [String: Any] else { return nil }
            let kids = (d["children"] as? [[String: Any]] ?? []).compactMap(node)
            return kids.isEmpty ? nil : .folder(label, kids)
        }
    }
}

// MARK: Safari

public struct SafariImporter: BookmarkImporter {
    public init() {}
    public var name: String { "Safari" }
    private var dir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari") }
    public var openPanelDirectory: URL { dir }
    public var openPanelMessage: String { "Choose Safari's “Bookmarks.plist”. (macOS only lets you pick it yourself.)" }
    public func candidateFiles() -> [URL] { [dir.appendingPathComponent("Bookmarks.plist")] }

    public func parse(_ data: Data) throws -> [BookmarkNode] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportError(message: "Not a Safari bookmarks file")
        }
        func node(_ d: [String: Any]) -> BookmarkNode? {
            switch d["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let url = d["URLString"] as? String else { return nil }
                let title = (d["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                return .link(title, url)
            case "WebBookmarkTypeList":
                let title = d["Title"] as? String ?? ""
                if title == "com.apple.ReadingList" { return nil }
                let kids = (d["Children"] as? [[String: Any]] ?? []).compactMap(node)
                let label = ["BookmarksBar": "Favorites", "BookmarksMenu": "Bookmarks Menu"][title] ?? title
                return .folder(label, kids)
            default: return nil
            }
        }
        return (root["Children"] as? [[String: Any]] ?? []).compactMap(node).filter { !$0.children.isEmpty || !$0.isFolder }
    }
}

// MARK: Arc (pinned tabs and folders act as bookmarks)

public struct ArcImporter: BookmarkImporter {
    public init() {}
    public var name: String { "Arc" }
    private var dir: URL { support.appendingPathComponent("Arc") }
    public var openPanelDirectory: URL { dir }
    public var openPanelMessage: String { "Choose Arc's “StorableSidebar.json”." }
    public func candidateFiles() -> [URL] { [dir.appendingPathComponent("StorableSidebar.json")] }

    public func parse(_ data: Data) throws -> [BookmarkNode] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [[String: Any]],
              let main = containers.first(where: { $0["items"] != nil }) else {
            throw ImportError(message: "Not an Arc sidebar file")
        }
        var items: [String: [String: Any]] = [:]
        for case let d as [String: Any] in (main["items"] as? [Any] ?? []) { if let id = d["id"] as? String { items[id] = d } }

        func build(_ id: String, depth: Int = 0) -> BookmarkNode? {
            guard depth < 32, let item = items[id], let data = item["data"] as? [String: Any] else { return nil }
            if let tab = data["tab"] as? [String: Any], let url = tab["savedURL"] as? String {
                return .link(item["title"] as? String ?? tab["savedTitle"] as? String ?? "", url)
            }
            if data["list"] != nil {
                let kids = (item["childrenIds"] as? [String] ?? []).compactMap { build($0, depth: depth + 1) }
                return .folder(item["title"] as? String ?? "Folder", kids)
            }
            return nil
        }

        var result: [BookmarkNode] = []
        for case let space as [String: Any] in (main["spaces"] as? [Any] ?? []) {
            let ids = space["containerIDs"] as? [Any] ?? []
            guard let p = ids.firstIndex(where: { ($0 as? String) == "pinned" }), p + 1 < ids.count,
                  let containerID = ids[p + 1] as? String, let container = items[containerID] else { continue }
            let kids = (container["childrenIds"] as? [String] ?? []).compactMap { build($0) }
            if !kids.isEmpty { result.append(.folder(space["title"] as? String ?? "Space", kids)) }
        }
        return result
    }
}

// MARK: Netscape HTML (exported by every browser)

public struct HTMLImporter: BookmarkImporter {
    public init() {}
    public var name: String { "HTML File" }
    public var openPanelDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads") }
    public var openPanelMessage: String { "Choose a bookmarks HTML file exported from any browser." }
    public func candidateFiles() -> [URL] { [] }

    public func parse(_ data: Data) throws -> [BookmarkNode] {
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError(message: "Unreadable file")
        }
        let pattern = "<(/?)DL[^>]*>|<H3[^>]*>(.*?)</H3>|<A\\s[^>]*?HREF=\"([^\"]*)\"[^>]*>(.*?)</A>"
        let re = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : decode(ns.substring(with: r))
        }
        var stack: [[BookmarkNode]] = [[]]
        var titles: [String] = []
        var pending: String?
        var rootSeen = false
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if let slash = group(m, 1) {
                if slash.isEmpty {
                    if !rootSeen && pending == nil { rootSeen = true; continue }  // the file's outermost list is the root
                    stack.append([]); titles.append(pending ?? ""); pending = nil
                } else if stack.count > 1 {
                    let kids = stack.removeLast(); let t = titles.removeLast()
                    stack[stack.count - 1].append(.folder(t, kids))
                }
            } else if let h3 = group(m, 2) {
                pending = h3
            } else if let href = group(m, 3) {
                stack[stack.count - 1].append(.link(group(m, 4) ?? "", href))
            }
        }
        while stack.count > 1 { let kids = stack.removeLast(); stack[stack.count - 1].append(.folder(titles.removeLast(), kids)) }
        return stack[0]
    }

    private func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

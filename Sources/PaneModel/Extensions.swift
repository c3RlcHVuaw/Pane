import Foundation

public struct InstalledExtension: Identifiable, Equatable, Sendable {
    public var id: String          // folder name inside the extensions directory
    public var name: String
    public var version: String
    public var detail: String
    public var path: String
    public var iconPath: String?
    public var enabled: Bool
}

public enum ExtensionError: Error, LocalizedError, Equatable {
    case notAnExtension, badArchive, download(String), unzip

    public var errorDescription: String? {
        switch self {
        case .notAnExtension: tr("That folder has no manifest.json, so it is not an extension.")
        case .badArchive: tr("That file is not a Chrome extension package.")
        case .download(let m): tr("Could not download the extension: \(m)")
        case .unzip: tr("Could not unpack the extension.")
        }
    }
}

/// Unpacked Chrome extensions that Pane hands to the engine at launch.
/// Content scripts, background scripts and extension pages work; there is no toolbar button or popup.
@MainActor
public final class ExtensionStore: ObservableObject {
    public static let shared = ExtensionStore()
    @Published public private(set) var items: [InstalledExtension] = []
    /// The extensions the running engine was started with; the list differing from it means a restart is needed.
    public private(set) var launchPaths: [String] = []
    private var root: URL?

    public var needsRestart: Bool { Set(items.filter(\.enabled).map(\.path)) != Set(launchPaths) }

    public func configure(root: URL) {
        self.root = root
        launchPaths = Self.enabledPaths(root: root)
        reload()
    }

    // MARK: Reading

    private nonisolated static func stateURL(_ root: URL) -> URL { root.appendingPathComponent("state.json") }
    private nonisolated static func disabled(_ root: URL) -> Set<String> {
        guard let d = try? Data(contentsOf: stateURL(root)), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = o["disabled"] as? [String] else { return [] }
        return Set(a)
    }

    /// Paths of the enabled extensions. Static so the engine can ask before the app finishes starting.
    public nonisolated static func enabledPaths(root: URL) -> [String] {
        let off = disabled(root)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) && !off.contains($0.lastPathComponent) }
            .map(\.path).sorted()
    }

    public nonisolated static func read(folder: URL, enabled: Bool) -> InstalledExtension? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let messages = localizedMessages(folder: folder, defaultLocale: m["default_locale"] as? String)
        func resolve(_ s: String?) -> String {
            guard let s else { return "" }
            if s.hasPrefix("__MSG_"), s.hasSuffix("__") { return messages[String(s.dropFirst(6).dropLast(2)).lowercased()] ?? "" }
            return s
        }
        var icon: String?
        if let icons = m["icons"] as? [String: String] {
            let best = icons.compactMap { k, v in Int(k).map { ($0, v) } }.sorted { $0.0 < $1.0 }
            if let pick = best.first(where: { $0.0 >= 32 }) ?? best.last { icon = folder.appendingPathComponent(pick.1).path }
        }
        let name = resolve(m["name"] as? String)
        return InstalledExtension(id: folder.lastPathComponent, name: name.isEmpty ? folder.lastPathComponent : name,
                                  version: m["version"] as? String ?? "", detail: resolve(m["description"] as? String),
                                  path: folder.path, iconPath: icon, enabled: enabled)
    }

    private nonisolated static func localizedMessages(folder: URL, defaultLocale: String?) -> [String: String] {
        for loc in [defaultLocale, "en", "en_US"].compactMap({ $0 }) {
            let f = folder.appendingPathComponent("_locales/\(loc)/messages.json")
            if let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                var out: [String: String] = [:]
                for (k, v) in o { if let msg = (v as? [String: Any])?["message"] as? String { out[k.lowercased()] = msg } }
                return out
            }
        }
        return [:]
    }

    public func reload() {
        guard let root else { items = []; return }
        let off = Self.disabled(root)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        items = dirs.compactMap { Self.read(folder: $0, enabled: !off.contains($0.lastPathComponent)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Changing

    private func saveDisabled(_ set: Set<String>) {
        guard let root else { return }
        let d = try? JSONSerialization.data(withJSONObject: ["disabled": set.sorted()])
        try? d?.write(to: Self.stateURL(root), options: .atomic)
    }

    public func setEnabled(_ id: String, _ on: Bool) {
        guard let root else { return }
        var off = Self.disabled(root)
        if on { off.remove(id) } else { off.insert(id) }
        saveDisabled(off)
        reload()
    }

    public func remove(_ id: String) {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
        reload()
    }

    /// Copies an unpacked extension folder in.
    @discardableResult
    public func add(folder: URL) throws -> String {
        guard let root, FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else { throw ExtensionError.notAnExtension }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var name = folder.lastPathComponent, n = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) { name = "\(folder.lastPathComponent)-\(n)"; n += 1 }
        try FileManager.default.copyItem(at: folder, to: root.appendingPathComponent(name))
        reload()
        return name
    }

    /// Installs a packed extension (.crx) from its bytes.
    @discardableResult
    public func install(crx data: Data, as name: String) throws -> String {
        guard let root, let zip = Self.zipPayload(ofCRX: data) else { throw ExtensionError.badArchive }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pane-ext-\(UUID().uuidString).zip")
        try zip.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", "-o", tmp.path, "-d", dest.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        // unzip exits 1 for harmless warnings (the CRX files carry a few); what matters is that a manifest came out.
        guard FileManager.default.fileExists(atPath: dest.appendingPathComponent("manifest.json").path) else {
            try? FileManager.default.removeItem(at: dest); throw ExtensionError.unzip
        }
        // Chrome ignores the folders the Web Store adds; the engine rejects a "_metadata" folder.
        try? FileManager.default.removeItem(at: dest.appendingPathComponent("_metadata"))
        reload()
        return name
    }

    /// The id inside a Chrome Web Store link, or the id itself.
    public nonisolated static func webStoreID(from input: String) -> String? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let isID: (String) -> Bool = { $0.count == 32 && $0.allSatisfy { ("a"..."p").contains($0) } }
        if isID(t) { return t }
        guard let u = URL(string: t), let host = u.host, host.contains("chromewebstore.google.com") || host.contains("chrome.google.com") else { return nil }
        return u.pathComponents.last(where: isID)
    }

    public func installFromWebStore(_ input: String) async throws {
        guard let id = Self.webStoreID(from: input) else { throw ExtensionError.download(tr("not a Chrome Web Store link")) }
        let url = URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=156.0.7&acceptformat=crx2,crx3&x=id%3D\(id)%26uc")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ExtensionError.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        try install(crx: data, as: id)
    }

    /// Strips the CRX2/CRX3 header and returns the zip archive inside.
    public nonisolated static func zipPayload(ofCRX d: Data) -> Data? {
        guard d.count > 16, d.prefix(4) == Data("Cr24".utf8) else { return nil }
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        let start: Int
        switch u32(4) {
        case 3: start = 12 + u32(8)
        case 2: start = 16 + u32(8) + u32(12)
        default: return nil
        }
        guard start < d.count else { return nil }
        return d.subdata(in: start..<d.count)
    }
}

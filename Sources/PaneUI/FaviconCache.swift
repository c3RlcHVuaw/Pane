import AppKit

/// Site icons keyed by host, kept in memory and on disk so they survive restarts.
@MainActor
final class FaviconCache {
    private let dir: URL?
    private var memory: [String: NSImage] = [:]

    /// With no directory the cache lives in memory only (private windows).
    init(directory: URL?) {
        dir = directory
        if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    private func key(_ url: String) -> String? {
        guard let h = URL(string: url)?.host?.lowercased(), !h.isEmpty else { return nil }
        return h.replacingOccurrences(of: "/", with: "_")
    }

    func image(for url: String) -> NSImage? {
        guard let k = key(url) else { return nil }
        if let m = memory[k] { return m }
        guard let dir, let img = NSImage(contentsOf: dir.appendingPathComponent(k + ".png")) else { return nil }
        memory[k] = img
        return img
    }

    func set(_ image: NSImage, for url: String) {
        guard let k = key(url) else { return }
        memory[k] = image
        guard let dir, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent(k + ".png"), options: .atomic)
    }
}

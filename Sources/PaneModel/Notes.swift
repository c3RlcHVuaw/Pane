import Foundation

/// A note you pinned to a web address ("compare with the Figma pricing", "ask Anna about this"). Stays on this Mac.
public struct PageNote: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    public var text: String
    public var updated: Date
    public init(id: UUID = UUID(), url: String, title: String, text: String, updated: Date = Date()) {
        self.id = id; self.url = url; self.title = title; self.text = text; self.updated = updated
    }
}

@MainActor
public final class NoteStore: ObservableObject {
    @Published public private(set) var notes: [PageNote] = []
    private let file: URL?

    public init(directory: URL?) {
        file = directory?.appendingPathComponent("notes.json")
        if let file, let data = try? Data(contentsOf: file), let n = try? JSONDecoder().decode([PageNote].self, from: data) { notes = n }
    }

    public var isPersistent: Bool { file != nil }

    public func note(forURL url: String) -> PageNote? {
        let key = normalizedURL(url)
        return notes.first { normalizedURL($0.url) == key }
    }

    /// Saves the text for the page; empty text removes the note.
    public func set(url: String, title: String, text: String) {
        guard file != nil else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedURL(url)
        if t.isEmpty { notes.removeAll { normalizedURL($0.url) == key }; persist(); return }
        let clipped = String(t.prefix(4000))
        if let i = notes.firstIndex(where: { normalizedURL($0.url) == key }) { notes[i].text = clipped; notes[i].title = title; notes[i].updated = Date() }
        else if notes.count < 500 { notes.insert(PageNote(url: url, title: title, text: clipped), at: 0) }
        persist()
    }

    public func remove(_ id: UUID) { notes.removeAll { $0.id == id }; persist() }

    private func persist() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(notes) { try? data.write(to: file, options: .atomic) }
    }
}

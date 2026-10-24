import Combine
import Foundation

public struct DownloadItem: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case inProgress, complete, canceled }
    public var id: UUID
    public var engineID: Int
    public var name: String
    public var path: String
    public var date: Date
    public var state: State
    /// 0...100, or -1 when the size isn't known.
    public var percent: Int
    public var received: Int64
    public var total: Int64

    public var fraction: Double? { percent >= 0 ? Double(percent) / 100 : nil }
}

/// The downloads list shown from the toolbar: newest first, remembered across launches.
@MainActor
public final class DownloadsStore: ObservableObject {
    @Published public private(set) var items: [DownloadItem] = []
    public var onChange: (() -> Void)?
    private let limit: Int

    public init(limit: Int = 50) { self.limit = limit }

    public var hasActive: Bool { items.contains { $0.state == .inProgress } }

    /// Average progress of the downloads still running (nil when none are, or sizes are unknown).
    public var activeFraction: Double? {
        let f = items.filter { $0.state == .inProgress }.compactMap(\.fraction)
        return f.isEmpty ? nil : f.reduce(0, +) / Double(f.count)
    }

    /// Records an update from the engine. Returns the item and whether it has just completed.
    @discardableResult
    public func update(engineID: Int, name: String, path: String, percent: Int, received: Int64, total: Int64,
                       state: DownloadItem.State, now: Date = Date()) -> (item: DownloadItem, justCompleted: Bool) {
        let index = items.firstIndex { $0.engineID == engineID && $0.state == .inProgress }
        var item = index.map { items[$0] } ?? DownloadItem(id: UUID(), engineID: engineID, name: name, path: path, date: now,
                                                           state: .inProgress, percent: percent, received: received, total: total)
        let wasActive = item.state == .inProgress
        if !name.isEmpty { item.name = name }
        if !path.isEmpty { item.path = path }
        item.percent = state == .complete ? 100 : percent
        item.received = received; item.total = total; item.state = state
        if state != .inProgress { item.date = now }
        if let index { items[index] = item } else { items.insert(item, at: 0) }
        if items.count > limit { items.removeLast(items.count - limit) }
        onChange?()
        return (item, wasActive && state == .complete)
    }

    public func remove(_ id: UUID) { items.removeAll { $0.id == id }; onChange?() }

    /// Clears finished and canceled entries; running downloads stay.
    public func clearFinished() { items.removeAll { $0.state != .inProgress }; onChange?() }

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(items.filter { $0.state != .inProgress })
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    public func load(from url: URL) -> Bool {
        guard let d = try? Data(contentsOf: url), let i = try? JSONDecoder().decode([DownloadItem].self, from: d) else { return false }
        items = i
        return true
    }
}

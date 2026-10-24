import Foundation

/// Notices that the last run ended badly and prepares an anonymous report from macOS's own crash log.
/// Nothing is sent unless the user says yes, and a report holds no addresses, no page content and no personal data:
/// just the app build, the system version, the kind of crash and the function names where it happened.
public struct CrashSummary: Codable, Equatable, Sendable {
    public var app: String
    public var system: String
    public var kind: String
    public var thread: String
    public var frames: [String]
    public var when: String

    public var text: String {
        "Pane \(app) on macOS \(system)\n\(kind) on \(thread) at \(when)\n" + frames.enumerated().map { "\($0.offset). \($0.element)" }.joined(separator: "\n")
    }
}

public enum CrashReporter {
    /// A flag file that exists only while Pane is running normally. If it is still there at launch, the last run didn't end cleanly.
    /// Returns when the previous run started if it never ended cleanly, otherwise nil.
    public static func markLaunch(in dir: URL) -> Date? {
        let flag = dir.appendingPathComponent("running.flag")
        let previous = (try? String(contentsOf: flag, encoding: .utf8)).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(Date().timeIntervalSince1970)".write(to: flag, atomically: true, encoding: .utf8)
        return previous
    }

    public static func markCleanExit(in dir: URL) { try? FileManager.default.removeItem(at: dir.appendingPathComponent("running.flag")) }

    /// The newest Pane crash log from the last two days, if there is one.
    public static func latestSummary(after: Date = .distantPast, reportsDirectory: URL? = nil, now: Date = Date()) -> CrashSummary? {
        let dir = reportsDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let recent = files.filter { $0.lastPathComponent.hasPrefix("Pane-") && $0.pathExtension == "ips" }
            .compactMap { f -> (URL, Date)? in
                guard let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, now.timeIntervalSince(d) < 2 * 86400, d >= after else { return nil }
                return (f, d)
            }
            .sorted { $0.1 > $1.1 }
        guard let newest = recent.first, let text = try? String(contentsOf: newest.0, encoding: .utf8) else { return nil }
        return summary(fromIPS: text)
    }

    /// An .ips file is a one-line JSON header followed by the JSON report.
    public static func summary(fromIPS text: String) -> CrashSummary? {
        guard let nl = text.firstIndex(of: "\n"), let data = String(text[text.index(after: nl)...]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let bundle = o["bundleInfo"] as? [String: Any]
        let app = "\(bundle?["CFBundleShortVersionString"] as? String ?? "?") (\(bundle?["CFBundleVersion"] as? String ?? "?"))"
        let os = (o["osVersion"] as? [String: Any])?["train"] as? String ?? "?"
        let exc = o["exception"] as? [String: Any]
        let kind = [exc?["type"] as? String, exc?["signal"] as? String].compactMap { $0 }.joined(separator: " / ")
        let threads = o["threads"] as? [[String: Any]] ?? []
        let faulting = (o["faultingThread"] as? Int).flatMap { $0 < threads.count ? threads[$0] : nil } ?? threads.first { $0["triggered"] as? Bool == true } ?? threads.first
        let images = o["usedImages"] as? [[String: Any]] ?? []
        let frames: [String] = (faulting?["frames"] as? [[String: Any]] ?? []).prefix(25).map { f in
            let image = (f["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
            let symbol = f["symbol"] as? String ?? "0x" + String((f["imageOffset"] as? Int) ?? 0, radix: 16)
            return "\(image): \(symbol)"
        }
        guard !frames.isEmpty else { return nil }
        return CrashSummary(app: app, system: os, kind: kind.isEmpty ? "crash" : kind, thread: (faulting?["name"] as? String) ?? (faulting?["queue"] as? String) ?? "thread",
                            frames: frames, when: o["captureTime"] as? String ?? "")
    }

    public static func send(_ summary: CrashSummary, to url: URL) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(summary)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

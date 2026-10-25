import Foundation
import AppKit

/// Notices when the app stops responding and saves a stack sample, so a freeze can be diagnosed afterwards.
/// A background thread asks the main thread to answer every second; if it takes more than eight seconds, it runs /usr/bin/sample.
final class HangWatchdog: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var lastBeat = Date()
    private var sampled = false

    init(directory: URL) { self.directory = directory }

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DispatchQueue.main.async { [self] in
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] _ in lock.lock(); lastBeat = Date(); sampled = false; lock.unlock() }
        }
        let t = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 2)
                lock.lock()
                let stalled = Date().timeIntervalSince(lastBeat) > 8 && !sampled
                if stalled { sampled = true }
                lock.unlock()
                if stalled { takeSample() }
            }
        }
        t.name = "pane.hang-watchdog"; t.qualityOfService = .utility
        t.start()
    }

    private func takeSample() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let out = directory.appendingPathComponent("hang-\(f.string(from: Date())).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-file", out.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        // Keep only the latest few.
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("hang-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(5) { try? FileManager.default.removeItem(at: old) }
    }
}

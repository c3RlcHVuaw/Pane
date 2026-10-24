import CryptoKit
import Foundation
import PaneModel

struct UpdateFeed: Decodable, Equatable {
    var version: String
    var build: Int
    var notes: String?
    var url: String
    var sha256: String
}

enum UpdateError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

enum UpdateInstaller {
    /// Shell script that waits for the app to quit, swaps the bundle (restoring the old one on failure) and relaunches.
    static func script(pid: Int32, app: String, new: String, backup: String) -> String {
        """
        #!/bin/bash
        PID=\(pid)
        APP=\(quote(app))
        NEW=\(quote(new))
        BACKUP=\(quote(backup))
        for i in $(seq 1 300); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        rm -rf "$BACKUP"
        if mv "$APP" "$BACKUP"; then
          if mv "$NEW" "$APP"; then
            xattr -dr com.apple.quarantine "$APP" 2>/dev/null
            rm -rf "$BACKUP"
          else
            mv "$BACKUP" "$APP"
          fi
        fi
        open "$APP"
        rm -rf "$(dirname "$NEW")" "$0"
        """
    }
    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Checks a JSON feed, downloads a zipped app, verifies it and swaps it in. No third-party code.
@MainActor
public final class DefaultAppUpdater: NSObject, AppUpdater, URLSessionDownloadDelegate {
    public private(set) var state: UpdateState = .idle { didSet { if state != oldValue { onChange?(state) } } }
    public var onChange: ((UpdateState) -> Void)?
    public var automaticChecks = true

    private let feedURL: URL
    private let currentBuild: Int
    private let appURL: URL
    private let bundleID: String
    private let terminate: @MainActor () -> Void
    private var timer: Timer?
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    public init(feedURL: URL, currentBuild: Int, appURL: URL = Bundle.main.bundleURL,
                bundleID: String = Bundle.main.bundleIdentifier ?? "", terminate: @escaping @MainActor () -> Void) {
        self.feedURL = feedURL; self.currentBuild = currentBuild; self.appURL = appURL
        self.bundleID = bundleID; self.terminate = terminate
    }

    // MARK: Checking

    public func start() {
        if automaticChecks { checkNow(userInitiated: false) }
        // A feed on disk is the developer loop: look often. A remote feed: every 15 minutes.
        let interval: TimeInterval = feedURL.isFileURL ? 10 : 900
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.automaticChecks == true { self?.checkNow(userInitiated: false) } }
        }
    }

    public func checkNow(userInitiated: Bool) {
        switch state {
        case .downloading, .installing, .checking: return
        case .available where !userInitiated: return
        default: break
        }
        if userInitiated { state = .checking }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: feedURL)
                let feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
                guard let url = URL(string: feed.url, relativeTo: feedURL)?.absoluteURL else { throw UpdateError.message(tr("Bad update URL")) }
                if feed.build > currentBuild {
                    state = .available(UpdateInfo(version: feed.version, build: feed.build, notes: feed.notes ?? "", url: url, sha256: feed.sha256))
                } else if userInitiated || state == .checking { state = .idle }
            } catch {
                if userInitiated { state = .failed(tr("Couldn't check for updates.")) } else if state == .checking { state = .idle }
            }
        }
    }

    // MARK: Installing

    public func install() {
        guard case .available(let info) = state else { return }
        state = .downloading(-1)
        Task {
            do {
                try await performInstall(info)
            } catch {
                state = .failed((error as? UpdateError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func performInstall(_ info: UpdateInfo) async throws {
        let parent = appURL.deletingLastPathComponent()
        if appURL.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: parent.path) {
            throw UpdateError.message(tr("Move Pane to your Applications folder, then update."))
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PaneUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let zip = try await download(info.url, into: work)
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == info.sha256.lowercased() else { throw UpdateError.message(tr("The download is damaged (checksum mismatch).")) }

        WhatsNew.save(version: info.version, build: info.build, notes: info.notes)
        let staging = work.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        guard let newApp = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.message(tr("The update has no app inside.")) }

        let plist = newApp.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist),
              dict["CFBundleIdentifier"] as? String == bundleID,
              Int(dict["CFBundleVersion"] as? String ?? "") == info.build else {
            throw UpdateError.message(tr("The update doesn't match what was announced."))
        }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])

        state = .installing
        let backup = parent.appendingPathComponent(".\(appURL.lastPathComponent).old").path
        let script = work.appendingPathComponent("install.sh")
        try UpdateInstaller.script(pid: ProcessInfo.processInfo.processIdentifier, app: appURL.path, new: newApp.path, backup: backup)
            .write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/bash '\(script.path)' >/dev/null 2>&1 &"]
        try p.run()
        p.waitUntilExit()
        terminate()
    }

    private func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { c.resume() } else {
                    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    c.resume(throwing: UpdateError.message(tool.hasSuffix("codesign") ? tr("The update's signature is invalid.") : String(localized: "Couldn't unpack the update. \(msg)")))
                }
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }

    // MARK: Download with progress

    private func download(_ url: URL, into dir: URL) async throws -> URL {
        let cfg = URLSessionConfiguration.ephemeral
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        session = s
        defer { s.finishTasksAndInvalidate(); session = nil }
        let tmp: URL = try await withCheckedThrowingContinuation { c in
            downloadContinuation = c
            s.downloadTask(with: url).resume()
        }
        let dest = dir.appendingPathComponent("update.zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    nonisolated public func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns, so move it somewhere stable first.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("pane-dl-\(UUID().uuidString)")
        do { try FileManager.default.moveItem(at: location, to: keep) } catch {
            MainActor.assumeIsolated { self.finishDownload(.failure(error)) }
            return
        }
        MainActor.assumeIsolated { self.finishDownload(.success(keep)) }
    }

    nonisolated public func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let f = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        MainActor.assumeIsolated { if case .downloading = self.state { self.state = .downloading(f) } }
    }

    nonisolated public func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated { self.finishDownload(.failure(error)) }
    }

    private func finishDownload(_ r: Result<URL, Error>) {
        guard let c = downloadContinuation else { return }
        downloadContinuation = nil
        c.resume(with: r)
    }
}

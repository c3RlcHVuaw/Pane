import Foundation

public struct UpdateInfo: Sendable, Equatable {
    public var version: String
    public var build: Int
    public var notes: String
    public var url: URL
    public var sha256: String
    public init(version: String, build: Int, notes: String, url: URL, sha256: String) {
        self.version = version; self.build = build; self.notes = notes; self.url = url; self.sha256 = sha256
    }
}

public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case available(UpdateInfo)
    case downloading(Double)  // 0...1, or -1 when unknown
    case installing
    case failed(String)
}

/// In-app updater. Implemented in PaneUpdate; the UI only shows its state and asks it to install.
@MainActor
public protocol AppUpdater: AnyObject {
    var state: UpdateState { get }
    var onChange: ((UpdateState) -> Void)? { get set }
    /// Background checks (at launch, periodically, when the app comes forward). Manual checks always work.
    var automaticChecks: Bool { get set }
    /// Starts the periodic background check (and checks right away).
    func start()
    func checkNow(userInitiated: Bool)
    /// Downloads, verifies and installs the available update, then relaunches the app.
    func install()
}

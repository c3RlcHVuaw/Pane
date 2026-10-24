import Combine
import Foundation

public struct AccountError: Error, LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Which member of Pane you are, and since when.
public struct MemberInfo: Equatable, Sendable {
    public var number: Int
    public var since: Date
    public init(number: Int, since: Date) { self.number = number; self.since = since }
}

/// What the account/sync engine offers the UI. Implemented in PaneSync.
@MainActor
public protocol AccountController: AnyObject {
    func register(email: String, password: String) async throws
    func signIn(email: String, password: String) async throws
    func signOut() async
    func deleteAccount(password: String) async throws
    /// Pushes local changes and pulls remote ones. Returns when the sync finished.
    func syncNow() async throws
    /// Turns on end-to-end encrypted syncing of saved logins with this passphrase (creating the vault on first use).
    func enablePasswordSync(passphrase: String) async throws
    func disablePasswordSync()
    /// The member number from the server, or nil when it can't be fetched.
    func memberInfo() async -> MemberInfo?
}

public extension AccountController {
    func memberInfo() async -> MemberInfo? { nil }
    func enablePasswordSync(passphrase: String) async throws {}
    func disablePasswordSync() {}
}

/// Observable account state for the UI: who is signed in and how syncing is going.
@MainActor
public final class AccountSession: ObservableObject {
    public enum Phase: Equatable { case signedOut, busy, signedIn }

    @Published public private(set) var phase: Phase = .signedOut
    @Published public private(set) var email: String = ""
    @Published public private(set) var lastSync: Date?
    @Published public private(set) var isSyncing = false
    @Published public var message: String?
    @Published public private(set) var member: MemberInfo?
    @Published public private(set) var syncPasswords = false
    @Published public var syncBookmarks: Bool { didSet { defaults.set(syncBookmarks, forKey: "syncBookmarks") } }
    @Published public var syncSettings: Bool { didSet { defaults.set(syncSettings, forKey: "syncSettings") } }

    public var controller: AccountController?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        syncBookmarks = defaults.object(forKey: "syncBookmarks") as? Bool ?? true
        syncSettings = defaults.object(forKey: "syncSettings") as? Bool ?? true
        syncPasswords = defaults.bool(forKey: "syncPasswords")
        if let n = defaults.object(forKey: "memberNumber") as? Int, let t = defaults.object(forKey: "memberSince") as? Double { member = MemberInfo(number: n, since: Date(timeIntervalSince1970: t)) }
    }

    // MARK: Actions (the UI calls these)

    public func register(email: String, password: String) async { await authenticate(email) { try await $0.register(email: email, password: password) } }
    public func signIn(email: String, password: String) async { await authenticate(email) { try await $0.signIn(email: email, password: password) } }

    private func authenticate(_ email: String, _ action: @MainActor (AccountController) async throws -> Void) async {
        guard let controller else { message = tr("Sync isn't available in this build."); return }
        message = nil
        phase = .busy
        do {
            try await action(controller)
            self.email = email.trimmingCharacters(in: .whitespaces).lowercased()
            phase = .signedIn
        } catch {
            phase = .signedOut
            message = (error as? AccountError)?.message ?? error.localizedDescription
        }
    }

    /// Enables encrypted password sync. Returns an error message, or nil on success.
    public func enablePasswordSync(passphrase: String) async -> String? {
        guard let controller else { return tr("Sync isn't available in this build.") }
        do {
            try await controller.enablePasswordSync(passphrase: passphrase)
            syncPasswords = true; defaults.set(true, forKey: "syncPasswords")
            while isSyncing { try? await Task.sleep(nanoseconds: 50_000_000) }  // let a sync already under way finish, then run one with passwords
            await syncNow()
            return nil
        } catch { return (error as? AccountError)?.message ?? error.localizedDescription }
    }

    public func disablePasswordSync() {
        controller?.disablePasswordSync()
        syncPasswords = false; defaults.set(false, forKey: "syncPasswords")
    }

    /// Asks the server for the member number (cached, so the card shows instantly next time).
    public func refreshMember() async {
        guard phase == .signedIn, let info = await controller?.memberInfo() else { return }
        member = info
        defaults.set(info.number, forKey: "memberNumber"); defaults.set(info.since.timeIntervalSince1970, forKey: "memberSince")
    }

    public func signOut() async {
        await controller?.signOut()
        email = ""; lastSync = nil; message = nil; phase = .signedOut
        member = nil; defaults.removeObject(forKey: "memberNumber"); defaults.removeObject(forKey: "memberSince")
        syncPasswords = false; defaults.set(false, forKey: "syncPasswords")
    }

    public func deleteAccount(password: String) async {
        do {
            try await controller?.deleteAccount(password: password)
            email = ""; lastSync = nil; message = nil; phase = .signedOut
        } catch { message = (error as? AccountError)?.message ?? error.localizedDescription }
    }

    public func syncNow() async {
        guard phase == .signedIn, let controller, !isSyncing else { return }
        isSyncing = true; message = nil
        defer { isSyncing = false }
        do { try await controller.syncNow() } catch { message = (error as? AccountError)?.message ?? tr("Couldn't sync. Will retry.") }
    }

    // MARK: Updates from the sync engine

    public func restore(email: String, lastSync: Date?) { self.email = email; self.lastSync = lastSync; phase = .signedIn }
    /// Debug aid: shows a member card without a server.
    public func debugSetMember(_ info: MemberInfo) { member = info }
    public func syncFinished(at date: Date) { lastSync = date; message = nil }
    public func sessionExpired() { email = ""; phase = .signedOut; message = tr("You were signed out. Please sign in again.") }
}

/// Lets the browser nudge the sync engine after local changes (it debounces).
@MainActor
public protocol SyncScheduler: AnyObject {
    func scheduleSync()
}

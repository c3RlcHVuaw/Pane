import CryptoKit
import Foundation
import PaneModel

struct SyncState: Codable {
    var email: String = ""
    var cursor: Int = 0
    var records: [String: SyncRecord] = [:]
    /// True once this Mac has either taken the synced preferences or published its own.
    var settingsAdopted: Bool?
    /// Logins: the edit time (ms) each one had when it was last synced, so unchanged ones aren't re-encrypted and re-sent.
    var loginStamps: [String: Int64]?
}

/// Keeps bookmarks and preferences in step across Macs: push local changes, pull remote ones,
/// resolve per record by newest edit. The merged records (not the live tree) are the source of truth.
@MainActor
public final class SyncEngine: AccountController, SyncScheduler {
    private let transport: SyncTransport
    private let tokens: TokenStore
    private let stateURL: URL
    private let bookmarks: BookmarkStore
    private let settings: AppSettings
    private let session: AccountSession
    private let clock: () -> Date

    private var state = SyncState()
    private var running = false
    private var again = false
    private var applying = false
    private var debounce: Task<Void, Never>?
    private var timer: Timer?
    /// The vault of the profile whose logins are synced (set by the app).
    public var vaultProvider: () -> PasswordVault? = { nil }
    private let vaultKey: KeychainSecretStore
    private var key: SymmetricKey? { vaultKey.value.flatMap(VaultCrypto.key(fromBase64:)) }

    public init(transport: SyncTransport, tokens: TokenStore, stateURL: URL, bookmarks: BookmarkStore,
                settings: AppSettings, session: AccountSession, vaultKey: KeychainSecretStore = KeychainSecretStore(account: "sync-vault-key"),
                clock: @escaping () -> Date = Date.init) {
        self.vaultKey = vaultKey
        self.transport = transport; self.tokens = tokens; self.stateURL = stateURL
        self.bookmarks = bookmarks; self.settings = settings; self.session = session; self.clock = clock
    }

    // MARK: Lifecycle

    /// Picks up a saved sign-in and starts background syncing.
    public func start() {
        loadState()
        if let email = tokens.email, tokens.token != nil {
            session.restore(email: email, lastSync: nil)
            scheduleSync(after: 1)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync(after: 0) }
        }
    }

    /// Called after local edits; waits a moment so a burst of changes becomes one sync.
    public func scheduleSync() { scheduleSync(after: 4) }

    func scheduleSync(after delay: TimeInterval) {
        guard !applying, session.phase == .signedIn else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.session.syncNow()
        }
    }

    // MARK: AccountController

    public func memberInfo() async -> MemberInfo? {
        guard let t = tokens.token else { return nil }
        return try? await transport.me(token: t)
    }

    public func register(email: String, password: String) async throws {
        try finishAuth(try await transport.register(email: email, password: password))
    }

    public func signIn(email: String, password: String) async throws {
        try finishAuth(try await transport.login(email: email, password: password))
    }

    private func finishAuth(_ auth: AuthResult) throws {
        tokens.save(token: auth.token, email: auth.email)
        if state.email != auth.email { state = SyncState(email: auth.email) }  // a different person: start clean
        saveState()
        Task { [weak self] in
            await self?.session.syncNow()
        }
    }

    public func enablePasswordSync(passphrase: String) async throws {
        guard let token = tokens.token else { throw AccountError(tr("You're not signed in.")) }
        guard passphrase.count >= 8 else { throw AccountError(tr("Use a passphrase of at least 8 characters.")) }
        var peek = state
        try await pullAll(token: token, into: &peek)
        struct Meta: Codable { var s: String; var c: String }
        if let rec = peek.records["vault"], !rec.deleted, let meta = try? JSONDecoder().decode(Meta.self, from: Data(rec.payload.utf8)),
           let salt = Data(base64Encoded: meta.s) {
            let k = VaultCrypto.deriveKey(passphrase: passphrase, salt: salt)
            guard VaultCrypto.open(meta.c, key: k) == VaultCrypto.checkText else { throw AccountError(tr("That isn't the passphrase you set. Try again.")) }
            vaultKey.save(VaultCrypto.keyData(k), trim: false)
        } else {
            let salt = VaultCrypto.randomSalt()
            let k = VaultCrypto.deriveKey(passphrase: passphrase, salt: salt)
            guard let check = VaultCrypto.seal(VaultCrypto.checkText, key: k),
                  let body = try? JSONEncoder().encode(Meta(s: salt.base64EncodedString(), c: check)), let payload = String(data: body, encoding: .utf8) else {
                throw AccountError(tr("Couldn't set up encryption."))
            }
            let rec = SyncRecord(id: "vault", type: "vault", payload: payload, updatedAt: nowMillis())
            try await transport.push(token: token, records: [rec])
            state.records["vault"] = rec
            vaultKey.save(VaultCrypto.keyData(k), trim: false)
        }
        state.loginStamps = [:]
        saveState()
    }

    public func disablePasswordSync() { vaultKey.clear(); state.loginStamps = nil; saveState() }

    public func signOut() async {
        if let t = tokens.token { try? await transport.logout(token: t) }
        forget()
    }

    public func deleteAccount(password: String) async throws {
        guard let t = tokens.token else { throw AccountError(tr("You're not signed in.")) }
        try await transport.deleteAccount(token: t, password: password)
        forget()
    }

    private func forget() {
        tokens.clear()
        vaultKey.clear()
        state = SyncState()
        try? FileManager.default.removeItem(at: stateURL)
        debounce?.cancel()
    }

    // MARK: Sync

    public func syncNow() async throws {
        guard let token = tokens.token else { throw AccountError(tr("You're signed out.")) }
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            do { try await runOnce(token: token) } catch TransportError.unauthorized {
                forget(); session.sessionExpired(); return
            }
        } while again
    }

    private func nowMillis() -> Int64 { Int64(clock().timeIntervalSince1970 * 1000) }

    private func runOnce(token: String) async throws {
        let now = nowMillis()
        var st = state

        // 0. First contact: look at what the server already has *for preferences only* before publishing
        //    anything. Otherwise a new Mac's default preferences would look like a fresh edit and overwrite
        //    the ones you chose elsewhere. (Bookmarks are merged normally below, so this peek is thrown away.)
        if st.cursor == 0, session.syncSettings, st.settingsAdopted != true {
            var peek = st
            try await pullAll(token: token, into: &peek)
            if let rec = peek.records["settings"], !rec.deleted {
                applying = true
                settings.applySynced(Self.decodeSettings(rec.payload))
                applying = false
                st.records["settings"] = rec  // now it matches what is applied here, so it isn't pushed back
            }
            st.settingsAdopted = true
        }

        // 1. What changed here since the last sync?
        var dirty: [SyncRecord] = []
        if session.syncBookmarks {
            let local = BookmarkRecords.records(bar: bookmarks.bar, other: bookmarks.other)
            for (id, l) in local {
                if let r = st.records[id], !r.deleted, r.type == l.type, r.payload == l.payload { continue }
                dirty.append(SyncRecord(id: id, type: l.type, payload: l.payload, updatedAt: now))
            }
            for (id, r) in st.records where (r.type == "bookmark" || r.type == "folder") && !r.deleted && local[id] == nil {
                dirty.append(SyncRecord(id: id, type: r.type, payload: "", updatedAt: now, deleted: true))  // deleted here
            }
        }
        if session.syncSettings {
            let payload = Self.encodeSettings(settings.syncable)
            if st.records["settings"]?.payload != payload {
                dirty.append(SyncRecord(id: "settings", type: "settings", payload: payload, updatedAt: now))
            }
        }

        // 1b. Saved logins, encrypted on this Mac before they leave it.
        if session.syncPasswords, let k = key, let vault = vaultProvider() {
            var stamps = st.loginStamps ?? [:]
            let local = vault.snapshot()
            let localIDs = Set(local.map { $0.login.id.uuidString })
            for (l, pw) in local {
                let ms = Int64(l.saved.timeIntervalSince1970 * 1000)
                if stamps[l.id.uuidString] == ms { continue }
                let body = (try? JSONSerialization.data(withJSONObject: ["h": l.host, "u": l.user, "p": pw])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard let sealed = VaultCrypto.seal(body, key: k) else { continue }
                dirty.append(SyncRecord(id: l.id.uuidString, type: "login", payload: sealed, updatedAt: ms))
                stamps[l.id.uuidString] = ms
            }
            for id in stamps.keys where !localIDs.contains(id) {
                dirty.append(SyncRecord(id: id, type: "login", payload: "", updatedAt: now, deleted: true))
                stamps[id] = nil
            }
            st.loginStamps = stamps
        }

        // 2. Push.
        var index = 0
        while index < dirty.count {
            let chunk = Array(dirty[index..<min(index + 500, dirty.count)])
            try await transport.push(token: token, records: chunk)
            for r in chunk { st.records[r.id] = r }
            index += chunk.count
        }

        // 3. Pull everything newer than our cursor.
        try await pullAll(token: token, into: &st)

        // 4. Apply the merged result here.
        applying = true
        if session.syncBookmarks {
            let merged = BookmarkRecords.tree(from: st.records)
            bookmarks.replaceRoots(bar: merged.bar, other: merged.other)
        }
        if session.syncSettings, let rec = st.records["settings"], !rec.deleted {
            settings.applySynced(Self.decodeSettings(rec.payload))
        }
        if session.syncPasswords, let k = key, let vault = vaultProvider() {
            var stamps = st.loginStamps ?? [:]
            let local = Dictionary(uniqueKeysWithValues: vault.logins.map { ($0.id.uuidString, $0) })
            for rec in st.records.values where rec.type == "login" {
                guard let id = UUID(uuidString: rec.id) else { continue }
                if rec.deleted {
                    if local[rec.id] != nil { vault.remove(id) }
                    stamps[rec.id] = nil
                    continue
                }
                if let l = local[rec.id], Int64(l.saved.timeIntervalSince1970 * 1000) >= rec.updatedAt { continue }
                guard let plain = VaultCrypto.open(rec.payload, key: k), let o = (try? JSONSerialization.jsonObject(with: Data(plain.utf8))) as? [String: String],
                      let host = o["h"], let user = o["u"], let pw = o["p"] else { continue }
                vault.apply(id: id, host: host, user: user, password: pw, saved: Date(timeIntervalSince1970: Double(rec.updatedAt) / 1000))
                stamps[rec.id] = rec.updatedAt
            }
            st.loginStamps = stamps
        }
        applying = false

        state = st
        saveState()
        session.syncFinished(at: clock())
    }

    // MARK: Helpers

    private func pullAll(token: String, into st: inout SyncState) async throws {
        while true {
            let page = try await transport.pull(token: token, since: st.cursor)
            for r in page.records {
                if let mine = st.records[r.id], mine.updatedAt > r.updatedAt { continue }
                st.records[r.id] = r
            }
            st.cursor = max(st.cursor, page.records.compactMap(\.seq).max() ?? st.cursor)
            if page.records.count < 5000 { st.cursor = max(st.cursor, page.seq); break }
        }
    }

    static func encodeSettings(_ values: [String: String]) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(values)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    static func decodeSettings(_ payload: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(payload.utf8))) ?? [:]
    }

    private func loadState() {
        guard let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(SyncState.self, from: d) else { return }
        state = s
    }

    private func saveState() {
        guard let d = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: stateURL, options: [.atomic])
    }
}

import XCTest
@testable import PaneModel
@testable import PaneSync

/// An in-memory stand-in for the server with the same rules: newest edit wins, tombstones, a cursor.
final class FakeServer: SyncTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: SyncRecord] = [:]
    private var seq = 0
    private var accounts: [String: String] = [:]
    private var _failPushes = false
    var failPushes: Bool {
        get { lock.withLock { _failPushes } }
        set { lock.withLock { _failPushes = newValue } }
    }

    func register(email: String, password: String) async throws -> AuthResult {
        try lock.withLock {
            if accounts[email] != nil { throw AccountError("An account with this email already exists.") }
            accounts[email] = password
            return AuthResult(token: "tok-\(email)", email: email)
        }
    }
    func login(email: String, password: String) async throws -> AuthResult {
        try lock.withLock {
            guard accounts[email] == password else { throw AccountError("Wrong email or password.") }
            return AuthResult(token: "tok-\(email)", email: email)
        }
    }
    func logout(token: String) async throws {}
    func deleteAccount(token: String, password: String) async throws {}
    func push(token: String, records recs: [SyncRecord]) async throws {
        try lock.withLock {
            if _failPushes { throw AccountError("offline") }
            for r in recs {
                if let e = records[r.id], e.updatedAt > r.updatedAt { continue }
                seq += 1
                var s = r; s.seq = seq
                records[r.id] = s
            }
        }
    }
    func pull(token: String, since: Int) async throws -> (seq: Int, records: [SyncRecord]) {
        lock.withLock { (seq, records.values.filter { ($0.seq ?? 0) > since }.sorted { ($0.seq ?? 0) < ($1.seq ?? 0) }) }
    }
}

@MainActor
final class SyncTests: XCTestCase {
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_800_000_000); func tick() -> Date { t += 10; return t } }

    private func mac(_ server: FakeServer, _ clock: Clock, name: String) -> (BookmarkStore, AppSettings, AccountSession, SyncEngine) {
        let defaults = UserDefaults(suiteName: "sync-\(name)-\(UUID())")!
        let b = BookmarkStore(), s = AppSettings(defaults: defaults), a = AccountSession(defaults: defaults)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sync-state-\(UUID()).json")
        let e = SyncEngine(transport: server, tokens: InMemoryTokenStore(), stateURL: url, bookmarks: b, settings: s, session: a, clock: { clock.tick() })
        a.controller = e
        return (b, s, a, e)
    }

    func testBookmarksTravelBetweenMacs() async {
        let server = FakeServer(), clock = Clock()
        let (b1, _, a1, _) = mac(server, clock, name: "one")
        let (b2, _, a2, _) = mac(server, clock, name: "two")

        await a1.register(email: "me@x.co", password: "password1")
        let folder = b1.addFolder("Reading", in: b1.bar.id)
        b1.add(title: "Swift", url: "https://swift.org", toFolder: folder)
        b1.add(title: "Home", url: "https://example.com")
        await a1.syncNow()

        await a2.signIn(email: "me@x.co", password: "password1")
        await a2.syncNow()
        XCTAssertEqual(b2.bar.children.count, b1.bar.children.count)
        XCTAssertEqual(b2.node(folder)?.children.first?.url, "https://swift.org")
        XCTAssertEqual(b2.bar.id, b1.bar.id)
    }

    func testDeletionsAndEditsMerge() async {
        let server = FakeServer(), clock = Clock()
        let (b1, _, a1, _) = mac(server, clock, name: "one")
        let (b2, _, a2, _) = mac(server, clock, name: "two")
        await a1.register(email: "me@x.co", password: "password1")
        let keep = b1.add(title: "Keep", url: "https://keep.com")
        let drop = b1.add(title: "Drop", url: "https://drop.com")
        await a1.syncNow()
        await a2.signIn(email: "me@x.co", password: "password1")
        await a2.syncNow()
        XCTAssertNotNil(b2.node(drop))

        b2.remove(drop)
        b2.rename(keep, to: "Kept")
        await a2.syncNow()
        await a1.syncNow()
        XCTAssertNil(b1.node(drop), "a deletion on one Mac removes it on the other")
        XCTAssertEqual(b1.node(keep)?.title, "Kept")
    }

    func testNewestEditWinsOnConflict() async {
        let server = FakeServer(), clock = Clock()
        let (b1, _, a1, _) = mac(server, clock, name: "one")
        let (b2, _, a2, _) = mac(server, clock, name: "two")
        await a1.register(email: "me@x.co", password: "password1")
        let id = b1.add(title: "Original", url: "https://x.com")
        await a1.syncNow()
        await a2.signIn(email: "me@x.co", password: "password1")
        await a2.syncNow()

        b1.rename(id, to: "From one")
        await a1.syncNow()
        b2.rename(id, to: "From two")  // later in time
        await a2.syncNow()
        await a1.syncNow()
        XCTAssertEqual(b1.node(id)?.title, "From two")
        XCTAssertEqual(b2.node(id)?.title, "From two")
    }

    func testSecondSyncChangesNothing() async {
        let server = FakeServer(), clock = Clock()
        let (b1, _, a1, _) = mac(server, clock, name: "one")
        await a1.register(email: "me@x.co", password: "password1")
        b1.add(title: "A", url: "https://a.com"); b1.add(title: "B", url: "https://b.com")
        await a1.syncNow()
        var changes = 0
        b1.onChange = { changes += 1 }
        await a1.syncNow()
        XCTAssertEqual(changes, 0, "an idle sync must not rewrite the bookmarks (no sync loops)")
    }

    func testFailedPushLosesNothing() async {
        let server = FakeServer(), clock = Clock()
        let (b1, _, a1, _) = mac(server, clock, name: "one")
        await a1.register(email: "me@x.co", password: "password1")
        server.failPushes = true
        let id = b1.add(title: "Precious", url: "https://p.com")
        await a1.syncNow()
        XCTAssertNotNil(b1.node(id), "bookmark survives a failed sync")
        XCTAssertNotNil(a1.message)
        server.failPushes = false
        await a1.syncNow()
        let (b2, _, a2, _) = mac(server, clock, name: "two")
        await a2.signIn(email: "me@x.co", password: "password1")
        await a2.syncNow()
        XCTAssertNotNil(b2.node(id), "it arrives once the connection is back")
    }

    func testOrphansLandInOtherBookmarks() {
        let folder = UUID(), child = UUID()
        let recs: [String: SyncRecord] = [
            child.uuidString: SyncRecord(id: child.uuidString, type: "bookmark",
                                         payload: #"{"o":0,"p":"\#(folder.uuidString)","t":"Lost","u":"https://l.com"}"#, updatedAt: 1),
        ]
        let t = BookmarkRecords.tree(from: recs)
        XCTAssertEqual(t.other.children.map(\.id), [child], "children of a deleted folder are kept, not dropped")
        XCTAssertTrue(t.bar.children.isEmpty)
    }

    func testSettingsSyncAndValidate() async {
        let server = FakeServer(), clock = Clock()
        let (_, s1, a1, _) = mac(server, clock, name: "one")
        let (_, s2, a2, _) = mac(server, clock, name: "two")
        await a1.register(email: "me@x.co", password: "password1")
        s1.searchEngineID = "duckduckgo"
        await a1.syncNow()
        await a2.signIn(email: "me@x.co", password: "password1")
        await a2.syncNow()
        XCTAssertEqual(s2.searchEngineID, "duckduckgo")
    }

    func testSigningOutClearsLocalSyncState() async {
        let server = FakeServer(), clock = Clock()
        let (b1, _, a1, _) = mac(server, clock, name: "one")
        await a1.register(email: "me@x.co", password: "password1")
        b1.add(title: "A", url: "https://a.com")
        await a1.syncNow()
        await a1.signOut()
        XCTAssertEqual(a1.phase, .signedOut)
        XCTAssertEqual(b1.bar.children.count, 1, "signing out keeps this Mac's bookmarks")
    }
}

/// Opt-in end-to-end check against a real server: PANE_SYNC_E2E=https://host swift test --filter LiveServerTests
@MainActor
final class LiveServerTests: XCTestCase {
    func testTwoMacsAgainstTheRealServer() async throws {
        guard let base = ProcessInfo.processInfo.environment["PANE_SYNC_E2E"], let url = URL(string: base) else {
            throw XCTSkip("set PANE_SYNC_E2E to run")
        }
        let transport = HTTPTransport(baseURL: url)
        func mac(_ n: String) -> (BookmarkStore, AppSettings, AccountSession, InMemoryTokenStore) {
            let d = UserDefaults(suiteName: "live-\(n)-\(UUID())")!
            let b = BookmarkStore(), s = AppSettings(defaults: d), a = AccountSession(defaults: d), t = InMemoryTokenStore()
            let e = SyncEngine(transport: transport, tokens: t, stateURL: FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID()).json"),
                               bookmarks: b, settings: s, session: a)
            a.controller = e
            return (b, s, a, t)
        }
        let email = "e2e\(Int.random(in: 100000...999999))@example.com", password = "e2e-password-123"
        let (b1, s1, a1, _) = mac("one"), (b2, s2, a2, _) = mac("two")

        await a1.register(email: email, password: password)
        XCTAssertEqual(a1.phase, .signedIn, a1.message ?? "")
        let folder = b1.addFolder("Live", in: b1.bar.id)
        let bm = b1.add(title: "Swift", url: "https://swift.org", toFolder: folder)
        s1.searchEngineID = "yandex"
        await a1.syncNow()
        XCTAssertNil(a1.message, a1.message ?? "")

        await a2.signIn(email: email, password: password)
        XCTAssertEqual(a2.phase, .signedIn, a2.message ?? "")
        await a2.syncNow()
        XCTAssertEqual(b2.node(bm)?.url, "https://swift.org")
        XCTAssertEqual(s2.searchEngineID, "yandex")

        await a2.signOut()
        await a2.signIn(email: email, password: "wrong-password-1")
        XCTAssertEqual(a2.phase, .signedOut)
        XCTAssertEqual(a2.message, "Wrong email or password.")

        await a1.deleteAccount(password: password)
        XCTAssertEqual(a1.phase, .signedOut, a1.message ?? "")
    }
}


@MainActor
final class PasswordSyncTests: XCTestCase {
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_800_000_000); func tick() -> Date { t += 10; return t } }

    private func mac(_ server: FakeServer, _ clock: Clock, _ tag: String) -> (PasswordVault, AccountSession, SyncEngine) {
        let defaults = UserDefaults(suiteName: "pw-\(tag)-\(UUID())")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID())")
        let vault = PasswordVault(directory: dir, service: "com.pane.browser.tests.\(UUID())")
        let a = AccountSession(defaults: defaults)
        let e = SyncEngine(transport: server, tokens: InMemoryTokenStore(), stateURL: FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID()).json"),
                           bookmarks: BookmarkStore(), settings: AppSettings(defaults: defaults), session: a,
                           vaultKey: KeychainSecretStore(service: "com.pane.browser.tests", account: "key-\(UUID())"), clock: { clock.tick() })
        e.vaultProvider = { vault }
        a.controller = e
        return (vault, a, e)
    }

    func testLoginsTravelEncryptedAndWrongPassphraseIsRefused() async {
        let server = FakeServer(), clock = Clock()
        let (v1, a1, _) = mac(server, clock, "one")
        let (v2, a2, _) = mac(server, clock, "two")
        await a1.register(email: "me@x.co", password: "password1")
        v1.save(host: "www.example.com", user: "anna", password: "s3cret pass")
        let err1 = await a1.enablePasswordSync(passphrase: "correct horse")
        XCTAssertNil(err1)
        XCTAssertTrue(a1.syncPasswords)
        XCTAssertEqual(v1.snapshot().count, 1)
        await a1.syncNow()
        await a1.syncNow()

        let onServer = (try? await server.pull(token: "tok-me@x.co", since: 0).records.map { $0.type }) ?? []
        XCTAssertTrue(onServer.contains("login") && onServer.contains("vault"), "server has \(onServer)")
        await a2.signIn(email: "me@x.co", password: "password1")
        let bad = await a2.enablePasswordSync(passphrase: "wrong passphrase")
        XCTAssertNotNil(bad)
        XCTAssertFalse(a2.syncPasswords)
        let good = await a2.enablePasswordSync(passphrase: "correct horse")
        XCTAssertNil(good)
        await a2.syncNow()
        let got = v2.logins(forHost: "example.com")
        XCTAssertEqual(got.map(\.user), ["anna"])
        XCTAssertEqual(got.first.flatMap { v2.password(for: $0) }, "s3cret pass")

        // The server never sees the password.
        let all = try? await server.pull(token: "tok-me@x.co", since: 0).records
        XCTAssertTrue(all?.filter { $0.type == "login" }.allSatisfy { !$0.payload.contains("s3cret") && !$0.payload.contains("anna") } ?? false)

        // Deleting on one Mac removes it on the other.
        v1.remove(v1.logins[0].id)
        await a1.syncNow()
        await a2.syncNow()
        XCTAssertTrue(v2.logins.isEmpty)
        for l in v1.logins + v2.logins { v1.remove(l.id) }
    }
}

final class KeychainProbeTests: XCTestCase {
    func testRoundTrip() {
        let k = KeychainSecretStore(service: "com.pane.browser.tests", account: "probe-\(UUID())")
        k.save("hello world ", trim: false)
        XCTAssertEqual(k.value, "hello world ")
        k.clear()
        XCTAssertNil(k.value)
    }
}

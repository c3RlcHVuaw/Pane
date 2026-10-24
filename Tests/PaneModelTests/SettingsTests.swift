import XCTest
@testable import PaneModel

@MainActor
final class SettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "pane-test-\(UUID())")!
        return d
    }

    func testSearchURLEncodesQueries() {
        let g = SearchEngine.named("google")
        XCTAssertEqual(g.url(for: "swift & c++"), "https://www.google.com/search?q=swift%20%26%20c%2B%2B")
        XCTAssertEqual(SearchEngine.named("nope").id, "google", "unknown engine falls back")
        XCTAssertEqual(SearchEngine.named("yandex").url(for: "привет"), "https://yandex.com/search/?text=%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82")
    }

    func testDefaultsAndPersistence() {
        let d = defaults()
        let s = AppSettings(defaults: d)
        XCTAssertEqual(s.searchEngineID, "google")
        XCTAssertEqual(s.sleepMinutes, 30)
        XCTAssertTrue(s.showBookmarksBar)
        var changed: [String] = []
        s.onChange = { changed.append($0) }
        s.searchEngineID = "duckduckgo"
        s.sleepMinutes = 0
        XCTAssertEqual(changed, ["searchEngine", "sleepMinutes"])
        let again = AppSettings(defaults: d)
        XCTAssertEqual(again.searchEngineID, "duckduckgo")
        XCTAssertEqual(again.sleepMinutes, 0)
    }

    func testNewTabURL() {
        let s = AppSettings(defaults: defaults())
        XCTAssertEqual(s.newTabPage, .startPage)
        XCTAssertEqual(s.newTabURL, "", "the start page is native, so there is nothing to load")
        s.newTabPage = .searchEngine
        XCTAssertEqual(s.newTabURL, "https://www.google.com")
        s.newTabPage = .blank
        XCTAssertEqual(s.newTabURL, "about:blank")
        s.newTabPage = .custom
        XCTAssertEqual(s.newTabURL, "https://www.google.com", "empty custom address falls back")
        s.customNewTabURL = "example.com"
        XCTAssertEqual(s.newTabURL, "https://example.com")
    }

    func testSyncedValuesAreValidated() {
        let s = AppSettings(defaults: defaults())
        s.applySynced(["searchEngine": "evil", "appearance": "dark", "sleepMinutes": "abc"])
        XCTAssertEqual(s.searchEngineID, "google", "unknown engines from the network are ignored")
        XCTAssertEqual(s.appearance, .dark)
        XCTAssertEqual(s.sleepMinutes, 30)
    }

    func testShortcutHints() {
        XCTAssertEqual(ShortcutCatalog.hint("Back", "Back"), "Back  ⌘[")
        XCTAssertEqual(ShortcutCatalog.hint("Whatever", "Not a shortcut"), "Whatever")
        let names = ShortcutCatalog.sections.flatMap(\.items).map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "shortcut names are unique")
    }
}

@MainActor
final class AccountSessionTests: XCTestCase {
    final class Fake: AccountController {
        var fail: String?
        var calls: [String] = []
        func register(email: String, password: String) async throws { calls.append("register"); if let f = fail { throw AccountError(f) } }
        func signIn(email: String, password: String) async throws { calls.append("signIn"); if let f = fail { throw AccountError(f) } }
        func signOut() async { calls.append("signOut") }
        func deleteAccount(password: String) async throws { calls.append("delete") }
        func syncNow() async throws { calls.append("sync") }
    }

    func testSignInFlow() async {
        let s = AccountSession(defaults: UserDefaults(suiteName: "acc-\(UUID())")!)
        let f = Fake(); s.controller = f
        await s.signIn(email: " Me@Example.com ", password: "secret123")
        XCTAssertEqual(s.phase, .signedIn)
        XCTAssertEqual(s.email, "me@example.com")
        await s.syncNow()
        XCTAssertEqual(f.calls, ["signIn", "sync"])
        await s.signOut()
        XCTAssertEqual(s.phase, .signedOut)
    }

    func testFailureKeepsSignedOutWithMessage() async {
        let s = AccountSession(defaults: UserDefaults(suiteName: "acc-\(UUID())")!)
        let f = Fake(); f.fail = "Wrong email or password."; s.controller = f
        await s.signIn(email: "a@b.co", password: "x")
        XCTAssertEqual(s.phase, .signedOut)
        XCTAssertEqual(s.message, "Wrong email or password.")
    }

    func testSyncRequiresSignIn() async {
        let s = AccountSession(defaults: UserDefaults(suiteName: "acc-\(UUID())")!)
        let f = Fake(); s.controller = f
        await s.syncNow()
        XCTAssertTrue(f.calls.isEmpty)
    }
}

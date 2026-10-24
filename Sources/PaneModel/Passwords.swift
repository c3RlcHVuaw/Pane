import Foundation

/// A saved login. The password itself lives only in the Keychain; this record is just who and where.
public struct SavedLogin: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var host: String
    public var user: String
    public var saved: Date
    public init(id: UUID = UUID(), host: String, user: String, saved: Date = Date()) { self.id = id; self.host = host; self.user = user; self.saved = saved }
}

/// Saved website logins of one profile. Passwords are filled only when the user asks (never automatically)
/// and only on the site they were saved for.
@MainActor
public final class PasswordVault: ObservableObject {
    @Published public private(set) var logins: [SavedLogin] = []
    private let file: URL?
    private let service: String

    public init(directory: URL?, service: String = "com.pane.browser.logins") {
        file = directory?.appendingPathComponent("logins.json")
        self.service = service
        if let file, let data = try? Data(contentsOf: file), let l = try? JSONDecoder().decode([SavedLogin].self, from: data) { logins = l }
    }

    public var isPersistent: Bool { file != nil }
    /// Called after a login was saved or removed here (not for ones applied from sync).
    public var onChange: (() -> Void)?

    /// Every saved login with its password, for encrypting into sync records.
    public func snapshot() -> [(login: SavedLogin, password: String)] {
        logins.compactMap { l in password(for: l).map { (l, $0) } }
    }

    /// Stores a login that arrived from another Mac, keeping its id and time.
    public func apply(id: UUID, host: String, user: String, password: String, saved: Date) {
        guard file != nil else { return }
        if let i = logins.firstIndex(where: { $0.id == id }) { logins[i].host = host; logins[i].user = user; logins[i].saved = saved }
        else { logins.append(SavedLogin(id: id, host: host, user: user, saved: saved)) }
        secret(id).save(password, trim: false)
        persist()
    }

    /// "www.example.com" and "example.com" are the same site.
    public static func normalize(host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    private func secret(_ id: UUID) -> KeychainSecretStore { KeychainSecretStore(service: service, account: id.uuidString) }

    public func logins(forHost host: String) -> [SavedLogin] {
        let h = Self.normalize(host: host)
        return logins.filter { $0.host == h }.sorted { $0.saved > $1.saved }
    }

    public func password(for login: SavedLogin) -> String? { secret(login.id).value }

    /// What saving would do for this login: nothing (already saved), update the password, or add a new login.
    public enum Outcome: Equatable { case unchanged, update, new }
    public func outcome(host: String, user: String, password: String) -> Outcome {
        guard let existing = logins(forHost: host).first(where: { $0.user == user }) else { return .new }
        return self.password(for: existing) == password ? .unchanged : .update
    }

    public func save(host: String, user: String, password: String) {
        guard file != nil, !password.isEmpty else { return }
        let h = Self.normalize(host: host)
        if let i = logins.firstIndex(where: { $0.host == h && $0.user == user }) {
            logins[i].saved = Date(); secret(logins[i].id).save(password, trim: false)
        } else {
            let l = SavedLogin(host: h, user: user)
            logins.append(l); secret(l.id).save(password, trim: false)
        }
        persist()
        onChange?()
    }

    public func remove(_ id: UUID) {
        secret(id).clear()
        logins.removeAll { $0.id == id }
        persist()
        onChange?()
    }

    private func persist() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(logins) { try? data.write(to: file, options: .atomic) }
    }
}

/// The scripts that watch login forms and fill them in.
public enum PasswordScripts {
    /// Reports a submitted login form through the console (the browser recognises the nonce and ignores everything else).
    public static func capture(nonce: String) -> String {
        """
        (() => {
          if (window.__paneCap) return;
          Object.defineProperty(window, '__paneCap', { value: true });
          const log = console.debug.bind(console);
          const grab = scope => {
            const inputs = Array.from((scope || document).querySelectorAll('input'));
            const pw = inputs.find(e => e.type === 'password' && e.value);
            if (!pw) return;
            const before = inputs.slice(0, inputs.indexOf(pw)).reverse();
            const user = before.find(e => (/^(text|email|tel)$/.test(e.type) || !e.type) && e.value);
            log('__pane:\(nonce):' + JSON.stringify({ u: user ? user.value : '', p: pw.value }));
          };
          document.addEventListener('submit', e => grab(e.target), true);
          document.addEventListener('click', e => {
            const b = e.target.closest && e.target.closest('button, input[type=submit], [role=button]');
            if (b) grab(b.closest('form') || document);
          }, true);
          document.addEventListener('keydown', e => {
            if (e.key === 'Enter' && e.target && e.target.type === 'password') grab(e.target.form || document);
          }, true);
        })()
        """
    }

    public static let hasLoginForm = "(() => Array.from(document.querySelectorAll('input[type=password]')).some(e => e.offsetParent !== null))()"

    public static func fill(user: String, password: String) -> String {
        func js(_ s: String) -> String {
            (try? JSONSerialization.data(withJSONObject: [s])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }
        return """
        (() => {
          const set = (el, v) => {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
            el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));
          };
          const pws = Array.from(document.querySelectorAll('input[type=password]')).filter(e => e.offsetParent !== null);
          if (!pws.length) return 'none';
          const pw = pws[0], inputs = Array.from((pw.form || document).querySelectorAll('input'));
          const user = inputs.slice(0, inputs.indexOf(pw)).reverse().find(e => /^(text|email|tel)$/.test(e.type) || !e.type);
          if (user && \(js(user))) set(user, \(js(user)));
          set(pw, \(js(password)));
          return 'ok';
        })()
        """
    }
}

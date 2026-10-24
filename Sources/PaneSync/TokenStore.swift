import Foundation
import Security

/// Where the signed-in session token lives.
public protocol TokenStore: AnyObject {
    var token: String? { get }
    var email: String? { get }
    func save(token: String, email: String)
    func clear()
}

public final class InMemoryTokenStore: TokenStore {
    public private(set) var token: String?
    public private(set) var email: String?
    public init() {}
    public func save(token: String, email: String) { self.token = token; self.email = email }
    public func clear() { token = nil; email = nil }
}

/// Keychain-backed. The items allow any app of this user to read them without a prompt: Pane is ad-hoc
/// signed, so every update changes its identity, and a per-app rule would ask for the login password
/// after each update.
public final class KeychainTokenStore: TokenStore {
    private let service: String
    public init(service: String = "com.pane.browser.sync") { self.service = service }

    public var token: String? { read("token") }
    public var email: String? { read("email") }

    public func save(token: String, email: String) { write("token", token); write("email", email) }
    public func clear() { delete("token"); delete("email") }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func write(_ account: String, _ value: String) {
        delete(account)
        var q = base(account)
        q[kSecValueData as String] = Data(value.utf8)
        var access: SecAccess?
        if SecAccessCreate("Pane Sync" as CFString, nil, &access) == errSecSuccess, let access { q[kSecAttrAccess as String] = access }
        SecItemAdd(q as CFDictionary, nil)
    }

    private func delete(_ account: String) { SecItemDelete(base(account) as CFDictionary) }
}

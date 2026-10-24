import Foundation
import Security

/// One secret (an API key or a saved password) in the Keychain. Only Pane may read it without asking;
/// Pane's signature stays the same across updates, so macOS asks once ("Always Allow") and not again.
public final class KeychainSecretStore: @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.pane.browser", account: String) { self.service = service; self.account = account }

    public var value: String? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public var hasValue: Bool { value?.isEmpty == false }

    public func save(_ secret: String, trim: Bool = true) {
        clear()
        let trimmed = trim ? secret.trimmingCharacters(in: .whitespacesAndNewlines) : secret
        guard !trimmed.isEmpty else { return }
        var q = base()
        q[kSecValueData as String] = Data(trimmed.utf8)
        var access: SecAccess?
        if SecAccessCreate("Pane" as CFString, nil, &access) == errSecSuccess, let access { q[kSecAttrAccess as String] = access }
        SecItemAdd(q as CFDictionary, nil)
    }

    public func clear() { SecItemDelete(base() as CFDictionary) }

    private func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

import CommonCrypto
import CryptoKit
import Foundation

/// End-to-end encryption for synced logins. The key comes from a passphrase that never leaves this Mac:
/// the server only ever stores ciphertext (AES-256-GCM) and a random salt.
enum VaultCrypto {
    static let iterations: UInt32 = 200_000
    static let checkText = "pane-vault-ok"

    static func randomSalt() -> Data { Data((0..<16).map { _ in UInt8.random(in: 0...255) }) }

    static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pass = Array(passphrase.utf8)
        _ = salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.map { Int8(bitPattern: $0) }, pass.count,
                                 saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &out, 32)
        }
        return SymmetricKey(data: Data(out))
    }

    static func seal(_ text: String, key: SymmetricKey) -> String? {
        guard let box = try? AES.GCM.seal(Data(text.utf8), using: key), let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    static func open(_ base64: String, key: SymmetricKey) -> String? {
        guard let data = Data(base64Encoded: base64), let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func keyData(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0).base64EncodedString() } }
    static func key(fromBase64 s: String) -> SymmetricKey? { Data(base64Encoded: s).map { SymmetricKey(data: $0) } }
}

import Foundation
import PaneModel

public struct AuthResult: Sendable { public var token: String; public var email: String }

public enum TransportError: Error, Equatable { case unauthorized }

public protocol SyncTransport: Sendable {
    func register(email: String, password: String) async throws -> AuthResult
    func login(email: String, password: String) async throws -> AuthResult
    func logout(token: String) async throws
    func deleteAccount(token: String, password: String) async throws
    func push(token: String, records: [SyncRecord]) async throws
    func pull(token: String, since: Int) async throws -> (seq: Int, records: [SyncRecord])
    func me(token: String) async throws -> MemberInfo?
}

public extension SyncTransport {
    func me(token: String) async throws -> MemberInfo? { nil }
}

/// Talks to the Pane sync server (server/server.js) over HTTPS.
public struct HTTPTransport: SyncTransport {
    let base: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) { base = baseURL; self.session = session }

    private func call(_ method: String, _ path: String, token: String? = nil, body: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL, timeoutInterval: 30)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw AccountError(tr("Can't reach the sync server. Check your connection."))
        }
        guard let http = resp as? HTTPURLResponse else { throw AccountError(tr("Unexpected reply from the sync server.")) }
        if (200..<300).contains(http.statusCode) { return data }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        if http.statusCode == 401, token != nil, path.hasPrefix("/api/sync") || path == "/api/logout" { throw TransportError.unauthorized }
        throw AccountError(message ?? String(localized: "The sync server returned an error (\(http.statusCode))."))
    }

    private func auth(_ path: String, _ email: String, _ password: String) async throws -> AuthResult {
        let data = try await call("POST", path, body: ["email": email, "password": password])
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let t = o["token"] as? String else {
            throw AccountError(tr("Unexpected reply from the sync server."))
        }
        return AuthResult(token: t, email: o["email"] as? String ?? email)
    }

    public func register(email: String, password: String) async throws -> AuthResult { try await auth("/api/register", email, password) }
    public func login(email: String, password: String) async throws -> AuthResult { try await auth("/api/login", email, password) }
    public func me(token: String) async throws -> MemberInfo? {
        let data = try await call("GET", "/api/me", token: token)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let n = o["number"] as? Int else { return nil }
        let since = (o["since"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        return MemberInfo(number: n, since: since)
    }
    public func logout(token: String) async throws { _ = try await call("POST", "/api/logout", token: token, body: [:]) }
    public func deleteAccount(token: String, password: String) async throws {
        _ = try await call("POST", "/api/account/delete", token: token, body: ["password": password])
    }

    public func push(token: String, records: [SyncRecord]) async throws {
        let list = records.map { r -> [String: Any] in
            ["id": r.id, "type": r.type, "payload": r.payload, "updatedAt": r.updatedAt, "deleted": r.deleted]
        }
        _ = try await call("POST", "/api/sync", token: token, body: ["records": list])
    }

    public func pull(token: String, since: Int) async throws -> (seq: Int, records: [SyncRecord]) {
        let data = try await call("GET", "/api/sync?since=\(since)", token: token)
        struct Reply: Decodable { var seq: Int; var records: [SyncRecord] }
        let r = try JSONDecoder().decode(Reply.self, from: data)
        return (r.seq, r.records)
    }
}

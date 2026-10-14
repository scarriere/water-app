import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

/// OAuth desktop-client flow: system browser + one-shot loopback callback + PKCE.
@MainActor
final class GoogleHealthAuth {
    struct Credentials: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var subject: String
        var email: String
    }

    enum AuthError: LocalizedError {
        case missingClientID, callback(String), missingHealthScope, tokenRejected(Int, String, String?)
        case missingRefreshToken, invalidResponse, noCredentials
        var errorDescription: String? {
            switch self {
            case .missingClientID: return "Set GOOGLE_HEALTH_CLIENT_ID in the Water build configuration."
            case .callback(let message): return "Google sign-in: \(message)"
            case .missingHealthScope:
                return "Google did not grant water-write permission. Select the Google Health nutrition permission on the consent screen; if it is not offered, check Google Health API access for this Cloud project."
            case .tokenRejected(let status, let code, let detail):
                return "Google token exchange failed (HTTP \(status), \(code))\(detail.map { ": \($0)" } ?? ".")"
            case .missingRefreshToken: return "Google did not grant offline access. Reconnect and allow access."
            case .invalidResponse: return "Unexpected Google OAuth response."
            case .noCredentials: return "Connect Google Health first."
            }
        }
    }

    static let healthScope = "https://www.googleapis.com/auth/googlehealth.nutrition.writeonly"
    private static let keychainService = "com.samtools.water.google-health"
    private let clientID: String
    private(set) var credentials: Credentials?

    init() {
        clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleHealthClientID") as? String ?? ""
        credentials = Self.readKeychain()
    }

    func disconnect() {
        credentials = nil
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService]
        SecItemDelete(query as CFDictionary)
    }

    func connect() async throws {
        guard !clientID.isEmpty else { throw AuthError.missingClientID }
        let state = UUID().uuidString
        let verifier = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let server = try LoopbackCallback()
        defer { server.cancel() }
        let redirect = "http://127.0.0.1:\(server.port)/callback"
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value:
                "openid email \(Self.healthScope)"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256")
        ]
        guard let url = parts.url, NSWorkspace.shared.open(url) else { throw AuthError.invalidResponse }
        let params = try await server.waitForCallback()
        guard params["state"] == state else { throw AuthError.callback("Invalid state; sign-in rejected.") }
        if let error = params["error"] { throw AuthError.callback(error) }
        guard let code = params["code"] else { throw AuthError.invalidResponse }
        let response = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "code_verifier": verifier, "client_id": clientID
        ])
        guard Self.scopeWasGranted(params["scope"]), Self.scopeWasGranted(response["scope"] as? String) else {
            throw AuthError.missingHealthScope
        }
        guard let refresh = response["refresh_token"] as? String else { throw AuthError.missingRefreshToken }
        guard let access = response["access_token"] as? String,
              let token = response["id_token"] as? String,
              let claims = Self.claims(in: token), let subject = claims["sub"] as? String,
              claims["aud"] as? String == clientID,
              let issuer = claims["iss"] as? String,
              ["accounts.google.com", "https://accounts.google.com"].contains(issuer),
              let expires = claims["exp"] as? TimeInterval, expires > Date().timeIntervalSince1970,
              let email = claims["email"] as? String else { throw AuthError.invalidResponse }
        let expiry = response["expires_in"] as? Double ?? 3600
        let value = Credentials(accessToken: access, refreshToken: refresh,
                                expiresAt: Date().addingTimeInterval(expiry), subject: subject, email: email)
        try Self.saveKeychain(value)
        credentials = value
    }

    func accessToken() async throws -> String {
        guard var value = credentials else { throw AuthError.noCredentials }
        if value.expiresAt > Date().addingTimeInterval(90) { return value.accessToken }
        let response = try await tokenRequest(["grant_type": "refresh_token",
                                                "refresh_token": value.refreshToken, "client_id": clientID])
        guard let access = response["access_token"] as? String else { throw AuthError.invalidResponse }
        value.accessToken = access
        value.expiresAt = Date().addingTimeInterval(response["expires_in"] as? Double ?? 3600)
        try Self.saveKeychain(value)
        credentials = value
        return access
    }

    static func scopeWasGranted(_ scopes: String?) -> Bool {
        guard let scopes else { return true } // Some providers omit the callback scope field.
        return scopes.split(separator: " ").contains(Substring(healthScope))
    }

    /// Include only short, plain-language Google errors; never render secrets or a callback URL.
    static func safeGoogleErrorDetail(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.count <= 200,
              !raw.contains("://"), !raw.contains("@"), !raw.contains("="),
              !raw.contains("\n"), !raw.contains("\r"),
              raw.range(of: #"[A-Za-z0-9_-]{28,}"#, options: .regularExpression) == nil else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
            .union(CharacterSet(charactersIn: " .,:;_-'()[]"))
        return raw.unicodeScalars.allSatisfy(allowed.contains) ? raw : nil
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            // Never show a token, authorization code, or untrusted error_description.
            let code = (json?["error"] as? String) ?? "unknown_error"
            let safe = code.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-").contains($0)
            } && code.count <= 80 ? code : "unknown_error"
            throw AuthError.tokenRejected(http.statusCode, safe,
                                          Self.safeGoogleErrorDetail(json?["error_description"] as? String))
        }
        guard let json else { throw AuthError.invalidResponse }
        return json
    }

    private static func claims(in token: String) -> [String: Any]? {
        let pieces = token.split(separator: ".")
        guard pieces.count == 3, let data = Data(base64URLEncoded: String(pieces[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func readKeychain() -> Credentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    private static func saveKeychain(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw AuthError.callback("Could not save credentials in Keychain (\(status)).") }
        } else if update != errSecSuccess {
            throw AuthError.callback("Could not update Keychain (\(update)).")
        }
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URLEncoded value: String) {
        let normal = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: normal + String(repeating: "=", count: (4 - normal.count % 4) % 4))
    }
}

/// A one-shot loopback server. Network.framework listeners fail with EINVAL on some Macs;
/// POSIX sockets also let us guarantee the callback is bound only to 127.0.0.1.
@MainActor
final class LoopbackCallback {
    let port: UInt16
    private let fd: Int32
    private let socketState = SocketState()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private var completed = false

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(0).bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        self.fd = fd
        self.port = in_port_t(bigEndian: address.sin_port)
        let state = socketState
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deadline = Date().addingTimeInterval(180)
            while !state.isClosed && Date() < deadline {
                var pendingSocket = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&pendingSocket, 1, 500)
                if ready < 0 && errno == EINTR { continue }
                if ready < 0 || (ready > 0 && pendingSocket.revents & Int16(POLLIN) == 0) { break }
                guard ready > 0 else { continue }
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { continue }
                let params = Self.readCallback(from: client)
                Darwin.close(client)
                if let params {
                    Task { @MainActor [weak self] in self?.finish(.success(params)) }
                    return
                }
            }
            Task { @MainActor [weak self] in
                self?.finish(.failure(GoogleHealthAuth.AuthError.callback("Sign-in timed out.")))
            }
        }
    }

    private nonisolated static func readCallback(from client: Int32) -> [String: String]? {
        var noSIGPIPE: Int32 = 1
        _ = withUnsafePointer(to: &noSIGPIPE) {
            Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var bytes = Data()
        while bytes.count < 8192 && bytes.range(of: Data("\r\n".utf8)) == nil {
            var chunk = [UInt8](repeating: 0, count: min(4096, 8192 - bytes.count))
            let count = chunk.withUnsafeMutableBytes { Darwin.recv(client, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { return nil }
            bytes.append(contentsOf: chunk.prefix(count))
        }
        let line = String(data: bytes, encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
        let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let url = URLComponents(string: "http://127.0.0.1\(path)")
        let valid = line.hasPrefix("GET /callback?") && url?.path == "/callback"
        let body = valid ? "Sign-in received. You can return to Water." : "Invalid callback."
        let response = "HTTP/1.1 \(valid ? "200 OK" : "404 Not Found")\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let data = Data(response.utf8)
        data.withUnsafeBytes { _ = Darwin.send(client, $0.baseAddress, $0.count, 0) }
        guard valid else { return nil }
        return Dictionary((url?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !completed else { return }
        completed = true
        socketState.close(fd)
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else { pending = result }
    }

    func waitForCallback() async throws -> [String: String] {
        if let pending { self.pending = nil; return try pending.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func cancel() {
        guard !completed else { return }
        finish(.failure(GoogleHealthAuth.AuthError.callback("Sign-in cancelled.")))
    }
}

private final class SocketState: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func close(_ fd: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

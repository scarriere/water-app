import AppKit
import CryptoKit
import Foundation
import Network
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
        case missingClientID, callback(String), missingRefreshToken, invalidResponse, noCredentials
        var errorDescription: String? {
            switch self {
            case .missingClientID: return "Set GOOGLE_HEALTH_CLIENT_ID in the Water build configuration."
            case .callback(let message): return "Google sign-in: \(message)"
            case .missingRefreshToken: return "Google did not grant offline access. Reconnect and allow access."
            case .invalidResponse: return "Unexpected Google OAuth response."
            case .noCredentials: return "Connect Google Health first."
            }
        }
    }

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
        let server = try await LoopbackCallback()
        defer { server.cancel() }
        let redirect = "http://127.0.0.1:\(server.port)/callback"
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value:
                "openid email https://www.googleapis.com/auth/googlehealth.nutrition.writeonly"),
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
        guard let refresh = response["refresh_token"] as? String,
              let access = response["access_token"] as? String,
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

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.callback("Token request was rejected; reconnect or check API access.")
        }
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

/// Binds only localhost; rejects all paths other than /callback and serves one response.
@MainActor
private final class LoopbackCallback {
    let port: UInt16
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private var completed = false

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        var started = false
        self.port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    guard !started else { return }
                    switch state {
                    case .ready:
                        started = true
                        if let port = listener.port { continuation.resume(returning: port.rawValue) }
                        else { continuation.resume(throwing: GoogleHealthAuth.AuthError.invalidResponse) }
                    case .failed(let error):
                        started = true
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            guard let self, self.continuation != nil else { return }
            self.cancel()
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            Task { @MainActor [weak self] in self?.receive(connection, bytes: Data()) }
        }
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - bytes.count) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var buffer = bytes
                if let data { buffer.append(data) }
                guard error == nil, buffer.count < 8192 else { connection.cancel(); return }
                guard buffer.range(of: Data("\r\n".utf8)) != nil else {
                    if complete { connection.cancel() } else { self.receive(connection, bytes: buffer) }
                    return
                }
                self.handle(connection, bytes: buffer)
            }
        }
    }

    private func handle(_ connection: NWConnection, bytes: Data) {
        let line = String(data: bytes, encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
        let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let url = URLComponents(string: "http://127.0.0.1\(path)")
        let valid = line.hasPrefix("GET /callback?") && url?.path == "/callback"
        let body = valid ? "Sign-in received. You can return to Water." : "Invalid callback."
        let response = "HTTP/1.1 \(valid ? "200 OK" : "404 Not Found")\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        guard valid, !completed else { return }
        completed = true
        let params = Dictionary((url?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: params)
        } else { pending = .success(params) }
    }

    func waitForCallback() async throws -> [String: String] {
        if let pending { self.pending = nil; return try pending.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func cancel() {
        listener.cancel()
        continuation?.resume(throwing: GoogleHealthAuth.AuthError.callback("Sign-in cancelled."))
        continuation = nil
    }
}

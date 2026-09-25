import AppKit
import CryptoKit
import Network
import Security

struct SpotifyAuthError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SpotifyOAuth {
    static let redirect = "http://127.0.0.1:43821/callback"
    static let scopes = "user-library-read user-library-modify"
    static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SpotifyAuthError(message: "Could not create a secure sign-in request.")
        }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    static func authorizeURL(clientID: String, verifier: String, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = ["client_id": clientID, "response_type": "code", "redirect_uri": redirect,
                                 "scope": scopes, "state": state, "code_challenge_method": "S256", "code_challenge": challenge(verifier)]
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
    static func trackURI(_ input: String) -> String? {
        let id: String
        if input.hasPrefix("spotify:track:") { id = String(input.dropFirst("spotify:track:".count)) }
        else { id = input }
        guard id.count == 22, id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return "spotify:track:" + id
    }
    // Invalid routes/states are ignored, never allowed to consume the login.
    static func callback(_ target: String, state: String) -> Result<String, SpotifyAuthError>? {
        guard target.hasPrefix("/callback?"), let c = URLComponents(string: "http://127.0.0.1:43821" + target), c.path == "/callback" else { return nil }
        let items = c.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == state else { return nil }
        if items.contains(where: { $0.name == "error" }) { return .failure(SpotifyAuthError(message: "Spotify sign-in was declined. You can try again whenever you’re ready.")) }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty else { return nil }
        return .success(code)
    }
}

struct SpotifyCredential: Codable {
    var clientID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

protocol SpotifyCredentialStore {
    func load() throws -> SpotifyCredential?
    func save(_ credential: SpotifyCredential) throws
    func clear() throws
}

struct SpotifyKeychain: SpotifyCredentialStore {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: "dev.reuben.Undertone.spotify",
                                      kSecAttrAccount as String: "library-oauth"] }
    func load() throws -> SpotifyCredential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return try JSONDecoder().decode(SpotifyCredential.self, from: data)
    }
    func save(_ credential: SpotifyCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw keychainError(updated) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }
    private func keychainError(_ status: OSStatus) -> SpotifyAuthError {
        SpotifyAuthError(message: "Keychain could not store or read the Spotify connection (\(status)). Try signing in again and allow Keychain access if prompted.")
    }
}

// The callback listener is restricted to IPv4 loopback. It exists only during
// sign-in, validates OAuth state, rejects oversized requests, and times out.
@MainActor final class SpotifyLoopback {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var timeout: Task<Void, Never>?

    func authorize(at url: URL, state: String) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 43821)
                    let server = try NWListener(using: parameters)
                    listener = server
                    server.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor in self?.accept(connection, state: state) }
                    }
                    var opened = false
                    server.stateUpdateHandler = { [weak self] status in
                        Task { @MainActor in
                            guard let self, self.continuation != nil else { return }
                            switch status {
                            case .ready:
                                if !opened {
                                    opened = true
                                    if !NSWorkspace.shared.open(url) { self.finish(.failure(SpotifyAuthError(message: "Could not open the Spotify sign-in page."))) }
                                }
                            case .failed:
                                self.finish(.failure(SpotifyAuthError(message: "Could not open the local sign-in callback. Another app may be using port 43821. Close it and retry.")))
                            default: break
                            }
                        }
                    }
                    server.start(queue: .main)
                    timeout = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 300_000_000_000)
                        guard !Task.isCancelled else { return }
                        self?.finish(.failure(SpotifyAuthError(message: "Spotify sign-in timed out. Please try again.")))
                    }
                } catch { finish(.failure(error)) }
            }
        }, onCancel: { Task { @MainActor in self.cancel() } })
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func accept(_ connection: NWConnection, state: String) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        read(connection, id: id, bytes: Data(), state: state)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.connections.removeValue(forKey: id)?.cancel()
        }
    }
    private func read(_ connection: NWConnection, id: UUID, bytes: Data, state: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                let buffer = bytes + (data ?? Data())
                guard buffer.count <= 8192, error == nil else { self.connections.removeValue(forKey: id)?.cancel(); return }
                guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if complete { self.connections.removeValue(forKey: id)?.cancel() }
                    else { self.read(connection, id: id, bytes: buffer, state: state) }
                    return
                }
                let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                let result = parts.count == 3 && parts[0] == "GET" ? SpotifyOAuth.callback(String(parts[1]), state: state) : nil
                let body = result == nil ? "This is not a valid Undertone sign-in callback." : "You can return to Undertone. It will finish connecting to Spotify."
                let response = "HTTP/1.1 \(result == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                    Task { @MainActor in
                        self?.connections.removeValue(forKey: id)?.cancel()
                        if let result { self?.finish(result.mapError { $0 as Error }) }
                    }
                })
            }
        }
    }
    private func finish(_ result: Result<String, Error>) {
        let pending = continuation
        continuation = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        pending?.resume(with: result)
    }
}

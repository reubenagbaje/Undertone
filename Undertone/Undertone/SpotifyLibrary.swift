import Foundation
import Combine

@MainActor final class SpotifyLibrary: ObservableObject {
    @Published var clientID: String
    @Published private(set) var connected = false
    @Published private(set) var signingIn = false
    @Published private(set) var saving = false
    @Published private(set) var liked: Bool?
    @Published private(set) var explicitTrack: Bool?
    @Published private(set) var metadataError: String?
    private var metadataURI: String?
    private var metadataTask: Task<Void, Never>?
    private var metadataRequestID = UUID()
    private var metadataCache: [String: Bool] = [:]
    private var metadataRetry = Date.distantPast
    @Published private(set) var status = "Connect your Spotify account to use Liked Songs."
    @Published private(set) var error: String?
    private(set) var currentURI: String?
    private var credential: SpotifyCredential?
    private let store: SpotifyCredentialStore
    private let session: URLSession
    private var listener: SpotifyLoopback?
    private var loginTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var tokenTask: Task<SpotifyCredential, Error>?
    private var generation = UUID()
    private var lastCheck = Date.distantPast
    private var blockedUntil = Date.distantPast

    init(session: URLSession = .shared, store: SpotifyCredentialStore = SpotifyKeychain()) {
        self.session = session
        self.store = store
        self.clientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
        do {
            credential = try store.load()
            if let credential {
                clientID = credential.clientID
                connected = true
                status = "Connected to Spotify Liked Songs"
            }
        } catch { self.error = error.localizedDescription }
    }

    func signIn() {
        guard !signingIn else { return }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count == 32, id.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            error = "Paste the 32-character Client ID from your Spotify Developer app. Do not paste a client secret."
            return
        }
        clientID = id
        UserDefaults.standard.set(id, forKey: "spotifyClientID")
        signingIn = true; error = nil
        status = "Finish signing in in your browser…"
        let epoch = generation
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == epoch { self.signingIn = false; self.listener = nil } }
            do {
                let verifier = try SpotifyOAuth.randomString()
                let nonce = try SpotifyOAuth.randomString()
                let callback = SpotifyLoopback()
                self.listener = callback
                let code = try await callback.authorize(at: SpotifyOAuth.authorizeURL(clientID: id, verifier: verifier, state: nonce), state: nonce)
                let token = try await self.exchange(["grant_type": "authorization_code", "code": code,
                                                     "redirect_uri": SpotifyOAuth.redirect, "client_id": id, "code_verifier": verifier], clientID: id, previousRefresh: nil)
                try Task.checkCancellation()
                guard self.generation == epoch else { return }
                try self.store.save(token)
                self.credential = token
                self.connected = true
                self.status = "Connected to Spotify Liked Songs"
                self.syncTrack(self.currentURI ?? "", force: true)
                self.syncMetadata(self.currentURI ?? "")
            } catch is CancellationError {
                if self.generation == epoch { self.status = "Sign-in cancelled." }
            } catch {
                if self.generation == epoch { self.error = error.localizedDescription; self.status = "Spotify sign-in did not finish." }
            }
        }
    }

    func cancelSignIn() { loginTask?.cancel(); listener?.cancel() }
    func disconnect() {
        metadataTask?.cancel(); metadataTask = nil; metadataURI = nil; explicitTrack = nil; metadataError = nil
        generation = UUID()
        loginTask?.cancel(); listener?.cancel(); listener = nil
        lookupTask?.cancel(); tokenTask?.cancel(); tokenTask = nil
        credential = nil; connected = false; liked = nil; saving = false; signingIn = false
        blockedUntil = .distantPast
        status = "Disconnected from Spotify Liked Songs."
        do { try store.clear(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func syncTrack(_ raw: String, force: Bool = false) {
        let uri = SpotifyOAuth.trackURI(raw)
        let changed = uri != currentURI
        if changed { currentURI = uri; liked = nil; lookupTask?.cancel() }
        guard connected, let uri, !saving, Date() >= blockedUntil else { return }
        guard force || changed || Date().timeIntervalSince(lastCheck) >= 30 else { return }
        lookupTask?.cancel()
        lastCheck = Date()
        let epoch = generation
        lookupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let saved = try await self.fetchSaved(uri)
                try Task.checkCancellation()
                guard self.currentURI == uri, self.generation == epoch, !self.saving else { return }
                self.liked = saved; self.error = nil
            } catch is CancellationError { }
            catch {
                guard self.currentURI == uri, self.generation == epoch else { return }
                self.error = error.localizedDescription
            }
        }
    }

    // Catalog metadata uses the existing OAuth session without additional scopes.
    func syncMetadata(_ raw: String) {
        let uri = SpotifyOAuth.trackURI(raw)
        let changed = uri != metadataURI
        if changed {
            metadataTask?.cancel(); metadataTask = nil
            metadataURI = uri; explicitTrack = nil; metadataError = nil
            metadataRetry = .distantPast
        }
        guard connected, let uri else { return }
        if let cached = metadataCache[uri] { explicitTrack = cached; return }
        guard metadataTask == nil, Date() >= metadataRetry else { return }
        let epoch = generation
        let requestID = UUID()
        metadataRequestID = requestID
        metadataTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.metadataURI == uri, self.generation == epoch, self.metadataRequestID == requestID { self.metadataTask = nil } }
            do {
                let id = String(uri.dropFirst("spotify:track:".count))
                let data = try await self.request(path: "/tracks/" + id, method: "GET", uri: nil)
                struct Track: Decodable { let explicit: Bool }
                let track = try JSONDecoder().decode(Track.self, from: data)
                try Task.checkCancellation()
                guard self.metadataURI == uri, self.generation == epoch, self.metadataRequestID == requestID else { return }
                if self.metadataCache.count >= 100 { self.metadataCache.removeAll() }
                self.metadataCache[uri] = track.explicit
                self.explicitTrack = track.explicit; self.metadataError = nil
            } catch is CancellationError { }
            catch {
                guard self.metadataURI == uri, self.generation == epoch, self.metadataRequestID == requestID else { return }
                self.metadataError = "Track details unavailable: " + error.localizedDescription
                self.metadataRetry = Date().addingTimeInterval(30)
            }
        }
    }

    func toggleCurrent() async {
        guard connected, !saving, let uri = currentURI, let liked else { return }
        let target = !liked
        let epoch = generation
        saving = true; error = nil
        lookupTask?.cancel()
        defer { if generation == epoch { saving = false } }
        do {
            _ = try await request(path: "/me/library", method: target ? "PUT" : "DELETE", uri: uri)
            guard generation == epoch else { return }
            // Do not optimistically fill the heart: only a successful Spotify
            // response is allowed to change the displayed saved state.
            if currentURI == uri { self.liked = target; lastCheck = Date() }
            status = target ? "Added to Spotify Liked Songs" : "Removed from Spotify Liked Songs"
        } catch {
            guard generation == epoch else { return }
            self.error = error.localizedDescription
        }
        // If playback changed during the write, refresh the new song's state.
        if currentURI != uri, generation == epoch {
            saving = false
            syncTrack(currentURI ?? "", force: true)
        }
    }

    private func fetchSaved(_ uri: String) async throws -> Bool {
        let data = try await request(path: "/me/library/contains", method: "GET", uri: uri)
        guard let saved = try JSONDecoder().decode([Bool].self, from: data).first else {
            throw SpotifyAuthError(message: "Spotify returned an empty saved-song status. Please retry.")
        }
        return saved
    }

    private func request(path: String, method: String, uri: String?) async throws -> Data {
        guard Date() >= blockedUntil else { throw SpotifyAuthError(message: "Spotify asked us to wait before trying again.") }
        let epoch = generation
        for attempt in 0..<2 {
            let token = try await accessToken(forceRefresh: attempt == 1)
            try Task.checkCancellation()
            guard generation == epoch else { throw CancellationError() }
            var url = URLComponents(string: "https://api.spotify.com/v1" + path)!
            if let uri { url.queryItems = [URLQueryItem(name: "uris", value: uri)] }
            var request = URLRequest(url: url.url!)
            request.httpMethod = method
            request.timeoutInterval = 20
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard generation == epoch else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw SpotifyAuthError(message: "Spotify did not return a valid response.") }
            switch http.statusCode {
            case 200...299: return data
            case 401 where attempt == 0: continue
            case 401:
                disconnect()
                error = "Spotify authorization expired. Connect your account again."
                throw SpotifyAuthError(message: error!)
            case 403:
                throw SpotifyAuthError(message: "Spotify refused library access. Check the app's user allowlist, the developer account's Premium status, and reconnect to grant library permissions.")
            case 429:
                let delay = max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "30") ?? 30)
                blockedUntil = Date().addingTimeInterval(delay)
                throw SpotifyAuthError(message: "Spotify's request limit was reached. Try again in \(Int(min(delay, 86400))) seconds.")
            default:
                throw SpotifyAuthError(message: "Spotify could not update or read Liked Songs (HTTP \(http.statusCode)). Try again shortly.")
            }
        }
        throw SpotifyAuthError(message: "Please reconnect Spotify.")
    }

    private func accessToken(forceRefresh: Bool) async throws -> String {
        guard let current = credential else { throw SpotifyAuthError(message: "Connect Spotify in settings first.") }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        if let tokenTask { return try await tokenTask.value.accessToken }
        let epoch = generation
        // The shared refresh owns persistence. Cancelling a track lookup must
        // not discard a rotated refresh token that another lookup still needs.
        let task = Task { [self] in
            let refreshed = try await exchange(["grant_type": "refresh_token", "refresh_token": current.refreshToken, "client_id": current.clientID], clientID: current.clientID, previousRefresh: current.refreshToken)
            try Task.checkCancellation()
            guard generation == epoch else { throw CancellationError() }
            try store.save(refreshed)
            credential = refreshed
            return refreshed
        }
        tokenTask = task
        defer { if generation == epoch { tokenTask = nil } }
        return try await task.value.accessToken
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
        let scope: String?
    }
    private func exchange(_ fields: [String: String], clientID: String, previousRefresh: String?) async throws -> SpotifyCredential {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = SpotifyOAuth.form(fields)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpotifyAuthError(message: "Spotify could not authorize this connection. Check the Client ID and redirect URI, then sign in again.")
        }
        let result = try JSONDecoder().decode(TokenResponse.self, from: data)
        if let scopes = result.scope {
            let granted = Set(scopes.split(separator: " ").map(String.init))
            guard granted.isSuperset(of: ["user-library-read", "user-library-modify"]) else {
                throw SpotifyAuthError(message: "Spotify did not grant permission to read and update Liked Songs. Please reconnect and approve those permissions.")
            }
        }
        guard let refresh = result.refresh_token ?? previousRefresh, !refresh.isEmpty, !result.access_token.isEmpty else {
            throw SpotifyAuthError(message: "Spotify did not return a complete connection. Please sign in again.")
        }
        return SpotifyCredential(clientID: clientID, accessToken: result.access_token, refreshToken: refresh,
                                 expiresAt: Date().addingTimeInterval(result.expires_in))
    }
}

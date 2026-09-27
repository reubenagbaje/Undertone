import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
final class MemoryCredentials: SpotifyCredentialStore {
    var value: SpotifyCredential?
    init(expired: Bool = false) {
        value = SpotifyCredential(clientID: String(repeating: "a", count: 32), accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(expired ? -10 : 3600))
    }
    func load() throws -> SpotifyCredential? { value }
    func save(_ credential: SpotifyCredential) throws { value = credential }
    func clear() throws { value = nil }
}
final class MockSpotify: URLProtocol {
    struct Reply {
        var method: String
        var path: String
        var status: Int = 200
        var body: String = ""
        var headers: [String: String] = [:]
        var uri: String?
        var delay: Double = 0
    }
    static let lock = NSLock()
    static var replies: [Reply] = []
    static var failures: [String] = []
    static var requests = 0
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        guard !Self.replies.isEmpty else {
            Self.failures.append("Unexpected extra request")
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let reply = Self.replies.removeFirst()
        if request.httpMethod != reply.method || request.url?.path != reply.path { Self.failures.append("Incorrect endpoint or method") }
        if let uri = reply.uri {
            let actual = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "uris" }?.value
            if actual != uri { Self.failures.append("Incorrect Spotify URI") }
        }
        if reply.path != "/api/token", request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") != true { Self.failures.append("Missing bearer token") }
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            Self.lock.lock(); let cancelled = stopped; Self.lock.unlock()
            guard !cancelled else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.lock.unlock() }
    static func enqueue(_ items: [Reply]) { lock.lock(); replies.append(contentsOf: items); lock.unlock() }
    static func validate() {
        lock.lock(); defer { lock.unlock() }
        check(replies.isEmpty, "Not all expected requests were made")
        check(failures.isEmpty, failures.joined(separator: "; "))
    }
}

@main struct SpotifyTests {
    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Async check timed out")
    }
    @MainActor static func main() async throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        check(SpotifyOAuth.challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 PKCE challenge")
        let random = try SpotifyOAuth.randomString()
        check(random.count == 43, "Verifier entropy and length")
        check(SpotifyOAuth.callback("/callback?state=wrong&code=abc", state: "expected") == nil, "Reject callback state mismatch")
        check(SpotifyOAuth.callback("/wrong?state=expected&code=abc", state: "expected") == nil, "Reject wrong callback route")
        check(SpotifyOAuth.callback("/callback?state=expected&state=expected&code=abc", state: "expected") == nil, "Reject duplicate state")
        guard case .success("abc")? = SpotifyOAuth.callback("/callback?state=expected&code=abc", state: "expected") else { fatalError("Accept valid callback") }
        guard case .failure? = SpotifyOAuth.callback("/callback?state=expected&error=access_denied", state: "expected") else { fatalError("Report declined OAuth") }
        check(String(data: SpotifyOAuth.form(["code": "a+b&c=d"]), encoding: .utf8) == "code=a%2Bb%26c%3Dd", "Safe token form encoding")
        check(SpotifyOAuth.trackURI("spotify:local:artist:track") == nil, "Reject local-file tracks")
        let a = "spotify:track:7a3LWj5xSFhFRYmztS8wgK"
        let b = "spotify:track:4aawyAB9vmqN3uQ7FjRGTy"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSpotify.self]
        let session = URLSession(configuration: config)
        let store = MemoryCredentials()
        let library = SpotifyLibrary(session: session, store: store)
        MockSpotify.enqueue([.init(method: "GET", path: "/v1/me/library/contains", body: "[false]", uri: a)])
        library.syncTrack(a)
        try await waitUntil { library.liked != nil }
        check(library.liked == false, "Saved state read from Spotify")
        MockSpotify.enqueue([.init(method: "PUT", path: "/v1/me/library", uri: a, delay: 0.05)])
        let save = Task { await library.toggleCurrent() }
        try await waitUntil { library.saving }
        check(library.liked == false, "Heart must not fill before Spotify confirms")
        await save.value
        check(library.liked == true, "Successful Spotify save fills heart")
        MockSpotify.enqueue([.init(method: "DELETE", path: "/v1/me/library", status: 403, uri: a)])
        await library.toggleCurrent()
        check(library.liked == true && library.error != nil, "Failed removal preserves heart and reports error")
        MockSpotify.enqueue([.init(method: "DELETE", path: "/v1/me/library", uri: a)])
        await library.toggleCurrent()
        check(library.liked == false, "Successful removal clears heart")
        MockSpotify.enqueue([.init(method: "PUT", path: "/v1/me/library", uri: a, delay: 0.1),
                             .init(method: "GET", path: "/v1/me/library/contains", body: "[false]", uri: b)])
        let changing = Task { await library.toggleCurrent() }
        try await waitUntil { library.saving }
        library.syncTrack(b)
        await changing.value
        try await waitUntil { library.liked != nil }
        check(library.currentURI == b && library.liked == false, "An in-flight save cannot fill the next song's heart")
        library.disconnect()
        check(!library.connected && store.value == nil && library.liked == nil, "Disconnect clears credentials and heart")

        let expired = MemoryCredentials(expired: true)
        let refreshLibrary = SpotifyLibrary(session: session, store: expired)
        MockSpotify.enqueue([.init(method: "POST", path: "/api/token", body: "{\"access_token\":\"fresh-fixture\",\"expires_in\":3600}"),
                             .init(method: "GET", path: "/v1/me/library/contains", body: "[true]", uri: a)])
        refreshLibrary.syncTrack(a)
        try await waitUntil { refreshLibrary.liked != nil }
        check(refreshLibrary.liked == true && expired.value?.accessToken == "fresh-fixture", "Expired access token is refreshed and persisted")
        check(expired.value?.refreshToken == "fixture-refresh", "Absent rotated token preserves prior refresh token")
        MockSpotify.enqueue([.init(method: "DELETE", path: "/v1/me/library", status: 429, headers: ["Retry-After": "60"], uri: a)])
        await refreshLibrary.toggleCurrent()
        let requests = MockSpotify.requests
        await refreshLibrary.toggleCurrent()
        check(MockSpotify.requests == requests && refreshLibrary.liked == true, "Rate-limit backoff blocks repeated writes")
        let rotatingStore = MemoryCredentials(expired: true)
        let rotating = SpotifyLibrary(session: session, store: rotatingStore)
        MockSpotify.enqueue([.init(method: "POST", path: "/api/token", body: "{\"access_token\":\"rotated-access\",\"refresh_token\":\"rotated-refresh\",\"expires_in\":3600}", delay: 0.1),
                             .init(method: "GET", path: "/v1/me/library/contains", body: "[false]", uri: b)])
        let beforeRefresh = MockSpotify.requests
        rotating.syncTrack(a)
        try await waitUntil { MockSpotify.requests > beforeRefresh }
        rotating.syncTrack(b)
        try await waitUntil { rotating.liked != nil }
        check(rotatingStore.value?.refreshToken == "rotated-refresh", "Track-change cancellation must preserve a rotated refresh token")
        let metadata = SpotifyLibrary(session: session, store: MemoryCredentials())
        MockSpotify.enqueue([.init(method: "GET", path: "/v1/tracks/7a3LWj5xSFhFRYmztS8wgK", body: "{\"explicit\":true}")])
        metadata.syncMetadata(a)
        try await waitUntil { metadata.explicitTrack != nil }
        check(metadata.explicitTrack == true, "Explicit badge uses Spotify catalog flag")
        let beforeCached = MockSpotify.requests
        metadata.syncMetadata(a)
        check(MockSpotify.requests == beforeCached, "Metadata is cached for current track")
        MockSpotify.enqueue([.init(method: "GET", path: "/v1/tracks/4aawyAB9vmqN3uQ7FjRGTy", body: "{\"explicit\":false}", delay: 0.05)])
        metadata.syncMetadata(b)
        check(metadata.explicitTrack == nil, "Old explicit badge clears immediately on track change")
        try await waitUntil { metadata.explicitTrack != nil }
        check(metadata.explicitTrack == false, "Clean tracks do not show a badge")
        metadata.syncMetadata(a)
        check(metadata.explicitTrack == true, "Cached metadata restores correct badge")
        metadata.disconnect()
        check(metadata.explicitTrack == nil, "Disconnect clears catalog metadata")
        let failingMetadata = SpotifyLibrary(session: session, store: MemoryCredentials())
        MockSpotify.enqueue([.init(method: "GET", path: "/v1/tracks/7a3LWj5xSFhFRYmztS8wgK", status: 403)])
        failingMetadata.syncMetadata(a)
        try await waitUntil { failingMetadata.metadataError != nil }
        check(failingMetadata.explicitTrack == nil && failingMetadata.error == nil, "Metadata failure cannot break library controls or invent badge")
        let beforeRetry = MockSpotify.requests
        failingMetadata.syncMetadata(a)
        check(beforeRetry == MockSpotify.requests, "Metadata failures back off")
        let racingMetadata = SpotifyLibrary(session: session, store: MemoryCredentials())
        MockSpotify.enqueue([.init(method: "GET", path: "/v1/tracks/7a3LWj5xSFhFRYmztS8wgK", body: "{\"explicit\":true}", delay: 0.15),
                             .init(method: "GET", path: "/v1/tracks/4aawyAB9vmqN3uQ7FjRGTy", body: "{\"explicit\":false}")])
        let beforeMetadataRace = MockSpotify.requests
        racingMetadata.syncMetadata(a)
        try await waitUntil { MockSpotify.requests > beforeMetadataRace }
        racingMetadata.syncMetadata(b)
        try await waitUntil { racingMetadata.explicitTrack != nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        check(racingMetadata.explicitTrack == false, "Cancelled old track metadata cannot badge the next song")
        let queued = SpotifyLibrary(session: session, store: MemoryCredentials())
        MockSpotify.enqueue([.init(method: "GET", path: "/v1/me/player/queue", body: "{\"queue\":[{\"uri\":\"\(a)\",\"name\":\"Queued song\",\"artists\":[{\"name\":\"Artist\"}]}]}")])
        await queued.loadQueue()
        check(queued.queue.count == 1 && queued.queue[0].subtitle == "Artist", "Queue maps Spotify metadata")
        MockSpotify.enqueue([.init(method: "GET", path: "/v1/me/player/queue", status: 403)])
        await queued.loadQueue()
        check(queued.queueError != nil && !queued.queueLoading, "Queue permission error is recoverable")
        MockSpotify.enqueue([.init(method: "GET", path: "/v1/me/player/queue", body: "{\"queue\":[]}", delay: 0.1)])
        let queueTask = Task { await queued.loadQueue() }
        try await waitUntil { queued.queueLoading }
        queued.disconnect()
        await queueTask.value
        check(queued.queue.isEmpty && !queued.queueLoading, "Disconnect clears queue and rejects stale response")
        check(SpotifyOAuth.scopes.contains("user-read-currently-playing"), "Queue permission requested")
        print("PASS: queue parsing, missing permissions and disconnect race")
        MockSpotify.validate()
        session.invalidateAndCancel()
        print("PASS: explicit/clean catalog flags, metadata cache/backoff/cancellation, PKCE, callback/state validation, form encoding, track validation, library reads, save/remove, failure rollback, track-change race, disconnect, token refresh and rate-limit backoff")
    }
}

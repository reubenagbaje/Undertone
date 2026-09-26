import AppKit
import Combine

@MainActor final class SpotifyController: ObservableObject {
    @Published var title = "Your next favourite song"
    @Published var artist = "Connect Spotify to get started"
    @Published var album = ""
    @Published var artwork: NSImage? {
        didSet { waveformTint = Self.artworkTint(artwork); ambientColors = Self.artworkPalette(artwork) }
    }
    @Published private(set) var ambientColors: [NSColor] = [.darkGray, .black]
    @Published private(set) var waveformTint = NSColor(white: 0.7, alpha: 1)
    @Published private(set) var trackRevision = 0
    @Published private(set) var artworkRevision = UUID()
    private(set) var skipDirection = 1
    @Published private(set) var skipPulse = 0
    @Published private(set) var feedbackSymbol: String?
    private var feedbackTask: Task<Void, Never>?
    private let artworkCache = NSCache<NSURL, NSImage>()
    @Published var playing = false
    @Published var shuffling = false
    let library = SpotifyLibrary()
    private(set) var trackID = ""
    @Published var volume: Double = 50
    private var retry = SpotifyReconnectPolicy()
    private var lastScriptErrorCode: Int?
    private var suspended = false
    private var connectionGeneration = UUID()
    private var workspaceObservers: [NSObjectProtocol] = []
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var connected = false
    @Published var enabled = false
    @Published var error: String?
    private let queue = DispatchQueue(label: "Undertone.spotify")
    private var timer: Timer?
    private var polling = false
    private var seekState = PlaybackSeekState()
    private var artworkURL = ""
    private var artworkTask: Task<Void, Never>?

    func connect() {
        enabled = true
        retry.reset()
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func startAutomaticConnection() {
        guard workspaceObservers.isEmpty else { return }
        connect()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.spotify.client" else { return }
                Task { @MainActor in
                    guard let self, !self.retry.permissionDenied else { return }
                    self.retry.reset(); self.enabled = true; self.refresh()
                }
            })
        }
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        connectionGeneration = UUID()
        timer?.fireDate = value ? .distantFuture : Date()
        if value { artworkTask?.cancel(); artworkURL = "" }
        if !value { refresh() }
    }
    func shutdown() {
        timer?.invalidate(); timer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        artworkTask?.cancel(); feedbackTask?.cancel()
    }
    func setVolume(_ value: Double) {
        guard connected, value.isFinite else { return }
        volume = min(100, max(0, value))
        run("set sound volume to \(Int(volume))") { [weak self] _, message in
            self?.error = message; self?.refresh()
        }
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            error = "Install the Spotify desktop app first."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
    }

    private func run(_ body: String, completion: @escaping @MainActor (NSAppleEventDescriptor?, String?) -> Void) {
        queue.async {
            autoreleasepool {
                var error: NSDictionary?
                let script = NSAppleScript(source: "with timeout of 3 seconds\ntell application id \"com.spotify.client\"\n\(body)\nend tell\nend timeout")
                let result = script?.executeAndReturnError(&error)
                let message = error?[NSAppleScript.errorMessage] as? String
                let code = error?[NSAppleScript.errorNumber] as? Int
                DispatchQueue.main.async { self.lastScriptErrorCode = code; completion(result, message) }
            }
        }
    }

    func refresh() {
        guard enabled, !polling, !suspended, retry.allowsAttempt(at: ProcessInfo.processInfo.systemUptime) else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else {
            connected = false; playing = false; position = 0; duration = 0
            title = "Spotify is closed"; artist = "Open Spotify to choose some music"; album = ""
            artworkTask?.cancel(); artwork = nil; artworkURL = ""
            library.syncTrack("")
            library.syncMetadata("")
            return
        }
        polling = true
        let generation = connectionGeneration
        let seekRevision = seekState.revision
        let seekWasPending = seekState.pending
        run("""
        set t to current track
        return {name of t, artist of t, album of t, artwork url of t, duration of t, player position, player state as text, shuffling, id of t, sound volume}
        """) { [weak self] result, message in
            guard let self else { return }
            self.polling = false
            guard self.connectionGeneration == generation, !self.suspended else { return }
            if let message {
                self.error = "Spotify: \(message) If access was denied, enable Undertone under Privacy & Security → Automation, then reconnect."
                self.connected = false; self.playing = false
                self.retry.failed(code: self.lastScriptErrorCode, now: ProcessInfo.processInfo.systemUptime)
                // Only a denied Automation request needs explicit user recovery.
                if self.retry.permissionDenied { self.enabled = false }
                return
            }
            guard let result, result.numberOfItems == 10 else {
                self.retry.failed(code: nil, now: ProcessInfo.processInfo.systemUptime); return
            }
            self.retry.reset()
            self.volume = min(100, max(0, result.atIndex(10)?.doubleValue ?? 50))
            self.connected = true; self.error = nil
            self.title = result.atIndex(1)?.stringValue ?? "Unknown track"
            self.artist = result.atIndex(2)?.stringValue ?? "Unknown artist"
            self.album = result.atIndex(3)?.stringValue ?? ""
            // Spotify's desktop Apple Event returns milliseconds despite its sdef description.
            self.duration = max(0, (result.atIndex(5)?.doubleValue ?? 0) / 1000)
            if self.seekState.accepts(revision: seekRevision, pendingAtStart: seekWasPending) {
                self.position = min(self.duration, max(0, result.atIndex(6)?.doubleValue ?? 0))
            }
            self.playing = result.atIndex(7)?.stringValue == "playing"
            self.shuffling = result.atIndex(8)?.booleanValue ?? false
            let nextTrackID = result.atIndex(9)?.stringValue ?? ""
            let changedTrack = !self.trackID.isEmpty && !nextTrackID.isEmpty && self.trackID != nextTrackID
            self.trackID = nextTrackID
            if changedTrack { self.trackRevision += 1 }
            self.library.syncTrack(self.trackID)
            self.library.syncMetadata(self.trackID)
            self.loadArtwork(result.atIndex(4)?.stringValue ?? "")
        }
    }

    enum Command: String { case previous = "previous track", toggle = "playpause", next = "next track" }
    func command(_ command: Command) {
        guard connected else { return }
        if command == .next { animateSkip(direction: 1, symbol: "forward.end.fill") }
        if command == .previous { animateSkip(direction: -1, symbol: "backward.end.fill") }
        run(command.rawValue) { [weak self] _, message in
            self?.error = message
            self?.refresh()
        }
    }
    private func animateSkip(direction: Int, symbol: String) {
        skipDirection = direction
        skipPulse += 1
        feedbackSymbol = symbol
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
            self?.feedbackSymbol = nil
        }
    }
    func restartOrPrevious() {
        guard connected else { return }
        if position > 3 {
            animateSkip(direction: -1, symbol: "arrow.counterclockwise")
            seek(0)
        } else { command(.previous) }
    }
    func seek(_ seconds: Double) {
        guard connected, seconds.isFinite else { return }
        let value = min(duration, max(0, seconds))
        let token = seekState.begin()
        position = value // Keep both players at the drag target immediately.
        run("set player position to \(value)") { [weak self] _, message in
            guard let self, self.seekState.complete(token) else { return }
            self.error = message
            self.refresh() // Also restores Spotify's position if seeking failed.
        }
    }
    func toggleShuffle() {
        guard connected else { return }
        run("set shuffling to " + (shuffling ? "false" : "true")) { [weak self] _, message in
            self?.error = message
            self?.refresh()
        }
    }
    private static func artworkPalette(_ image: NSImage?) -> [NSColor] {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [.darkGray, .black] }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        var bins: [Int: (Double, Double, Double, Double)] = [:]
        for y in 0..<12 { for x in 0..<12 {
            guard let c = bitmap.colorAt(x: min(bitmap.pixelsWide - 1, x * bitmap.pixelsWide / 12), y: min(bitmap.pixelsHigh - 1, y * bitmap.pixelsHigh / 12))?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
            let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
            let key = Int(r * 5) * 36 + Int(g * 5) * 6 + Int(b * 5)
            let weight = 0.3 + Double(c.saturationComponent)
            let old = bins[key] ?? (0, 0, 0, 0)
            bins[key] = (old.0 + r * weight, old.1 + g * weight, old.2 + b * weight, old.3 + weight)
        } }
        let colors = bins.values.sorted { $0.3 > $1.3 }.prefix(3).map {
            NSColor(calibratedRed: $0.0 / $0.3, green: $0.1 / $0.3, blue: $0.2 / $0.3, alpha: 1)
        }
        return colors.isEmpty ? [.darkGray, .black] : colors
    }

    private static func artworkTint(_ image: NSImage?) -> NSColor {
        let fallback = NSColor(white: 0.7, alpha: 1)
        guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, total: CGFloat = 0
        for y in 0..<8 {
            for x in 0..<8 {
                guard let color = bitmap.colorAt(x: min(bitmap.pixelsWide - 1, (x * 2 + 1) * bitmap.pixelsWide / 16),
                                                 y: min(bitmap.pixelsHigh - 1, (y * 2 + 1) * bitmap.pixelsHigh / 16))?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                let brightness = color.brightnessComponent
                guard brightness > 0.12 && brightness < 0.95 else { continue }
                let weight = 0.15 + color.saturationComponent
                red += color.redComponent * weight
                green += color.greenComponent * weight
                blue += color.blueComponent * weight
                total += weight
            }
        }
        guard total > 0 else { return fallback }
        let average = NSColor(calibratedRed: red / total, green: green / total, blue: blue / total, alpha: 1)
        return NSColor(calibratedHue: average.hueComponent,
                       saturation: min(0.42, average.saturationComponent * 0.65),
                       brightness: 0.72, alpha: 1)
    }

    private func loadArtwork(_ address: String) {
        guard address != artworkURL else { return }
        artworkURL = address
        artworkTask?.cancel()
        guard let url = URL(string: address), url.scheme == "https" else {
            artwork = nil
            artworkRevision = UUID()
            return
        }
        if let cached = artworkCache.object(forKey: url as NSURL) {
            artwork = cached
            artworkRevision = UUID()
            return
        }
        // Keep the outgoing cover visible while the next one loads, avoiding a
        // placeholder flash in the middle of the flip transition.
        artworkTask = Task { [weak self] in
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200,
                      self?.artworkURL == address else { return }
                guard let image = NSImage(data: data) else { return }
                self?.artworkCache.setObject(image, forKey: url as NSURL)
                self?.artwork = image
                self?.artworkRevision = UUID()
            } catch {
                guard !Task.isCancelled, self?.artworkURL == address else { return }
                self?.artwork = nil
                self?.artworkRevision = UUID()
            }
        }
    }
}

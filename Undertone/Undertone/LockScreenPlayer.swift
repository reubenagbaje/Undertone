import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import CoreGraphics

// Adapted from SkyLightWindow (MIT), Copyright (c) 2025 Lakr Aream.
// See ThirdPartyNotices.txt. Private APIs are resolved at runtime so an OS
// update that removes a symbol disables this module instead of crashing launch.
@MainActor final class LockScreenSpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias Spaces = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    private var handle: UnsafeMutableRawPointer?
    private var connection: Int32 = 0
    private var space: UInt64 = 0
    private var showSpaces: Spaces?
    private var hideSpaces: Spaces?
    private var addWindows: AddWindows?
    private(set) var failure: String?

    private func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
    private func prepare() -> Bool {
        if space != 0 { return true }
        if handle == nil {
            handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW | RTLD_LOCAL)
        }
        guard let main = symbol("SLSMainConnectionID", as: MainConnection.self),
              let create = symbol("SLSSpaceCreate", as: Create.self),
              let level = symbol("SLSSpaceSetAbsoluteLevel", as: SetLevel.self),
              let show = symbol("SLSShowSpaces", as: Spaces.self),
              let hide = symbol("SLSHideSpaces", as: Spaces.self),
              let add = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self)
        else { failure = "This macOS version does not provide the required SkyLight APIs."; return false }
        connection = main()
        guard connection != 0 else { failure = "SkyLight connection unavailable."; return false }
        let candidate = create(connection, 1, 0)
        guard candidate != 0 else { failure = "Could not create a lock-screen Space."; return false }
        // Notification Center at Screen Lock, as used by SkyLightWindow.
        let result = level(connection, candidate, 400)
        guard result == 0 else {
            _ = hide(connection, [candidate] as CFArray)
            failure = "SkyLight rejected the Space level (\(result))."; return false
        }
        space = candidate; showSpaces = show; hideSpaces = hide; addWindows = add
        return true
    }
    func attach(_ window: NSWindow) -> Bool {
        guard prepare(), let addWindows, let showSpaces else { return false }
        showSpaces(connection, [NSNumber(value: space)] as CFArray)
        addWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        failure = nil
        return true
    }
    func hide() {
        if space != 0 { _ = hideSpaces?(connection, [NSNumber(value: space)] as CFArray) }
    }
    // Keep one hidden Space per process; WindowServer reclaims it on exit.
    // Function pointers remain valid because the framework handle stays loaded.
}


@MainActor final class LyricsStore: ObservableObject {
    @Published private(set) var tracks: [String: [TimedLyric]] = [:]
    @Published var message = "Import a timed .lrc file for the current song."
    private var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Undertone/Lyrics.json")
    }
    init() {
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: [TimedLyric]].self, from: data) { tracks = saved }
    }
    func importCurrentTrack(_ track: String) {
        guard !track.isEmpty else { message = "Play a Spotify track first."; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            Task { @MainActor in
                guard result == .OK, let url = panel.url, let self else { return }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 2_000_000 else { self.message = "Choose a lyrics file smaller than 2 MB."; return }
                    let lines = LRCParser.parse(try String(contentsOf: url, encoding: .utf8))
                    guard !lines.isEmpty else { self.message = "No [mm:ss] timestamps were found."; return }
                    var updated = self.tracks; updated[track] = lines
                    guard let fileURL = self.fileURL else { throw CocoaError(.fileNoSuchFile) }
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
                    self.tracks = updated; self.message = "Imported \(lines.count) timed lines for this song."
                } catch { self.message = "Could not import lyrics: \(error.localizedDescription)" }
            }
        }
    }
}

@MainActor final class LockVisualState: ObservableObject {
    @Published var artworkExpanded = false
    @Published var locked = false
    @Published var shrinking = false
    @Published var visible = false
    @Published var preview = false
    @Published var asleep = false
    @Published var destination = CGPoint.zero
    @Published var notchSize = CGSize(width: 250, height: 32)
}

final class LockMediaPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor final class LockScreenPlayerController: ObservableObject {
    @Published private(set) var status = "Experimental: macOS may hide app windows behind its secure lock screen."
    let lyrics = LyricsStore()
    let visual = LockVisualState()
    private let spotify: SpotifyController
    private let audio: AudioCapture
    private let notchRect: () -> CGRect
    private var policy = LockPresentationPolicy()
    private var window: LockMediaPanel?
    private let lockSpace = LockScreenSpace()
    private var inputTimer: Timer?
    private var orderingTask: Task<Void, Never>?
    private var dismissedForCurrentLock = false
    private var displayFrame = CGRect.zero
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var dismissal: Task<Void, Never>?
    var onSleepChanged: ((Bool) -> Void)?

    init(spotify: SpotifyController, audio: AudioCapture, notchRect: @escaping () -> CGRect) {
        self.spotify = spotify; self.audio = audio; self.notchRect = notchRect
    }
    func start() {
        guard distributedObservers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        // These names are not a documented delivery contract. Workspace events
        // additionally handle display sleep and fast user switching.
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lockChanged(locked) }
            })
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { $0.sleepChanged(true) }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.sleepChanged(false) }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { $0.sleepChanged(true) }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { $0.sleepChanged(false) }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification) {
            $0.refreshConsoleSession()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification) {
            $0.refreshConsoleSession()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { controller in
            controller.hide(); controller.reconcile()
        }
        observe(.default, .init("UndertonePresentationChanged")) { $0.reconcile() }
        observe(.default, UserDefaults.didChangeNotification) { $0.reconcile() }
        spotify.$playing.combineLatest(spotify.$connected).receive(on: RunLoop.main).sink { [weak self] playing, connected in
            guard let self else { return }
            // Keep a visible player usable after Pause, but do not create a new
            // locked player for media that was already paused before locking.
            self.policy.playing = connected && (playing || self.window != nil); self.reconcile()
        }.store(in: &subscriptions)
        reconcile()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping (LockScreenPlayerController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
        }
        observers.append((center, token))
    }
    func preview() {
        guard !policy.locked, !policy.asleep else { return }
        policy.preview = true; reconcile()
    }
    func dismissPreview() {
        policy.preview = false
        if policy.locked { dismissedForCurrentLock = true; hide() }
        else { transitionToNotch() }
    }
    private func refreshConsoleSession() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        policy.sessionActive = session?[kCGSessionOnConsoleKey as String] as? Bool ?? false
        if policy.sessionActive { reconcile() } else { hide() }
    }
    private func lockChanged(_ locked: Bool) {
        guard policy.locked != locked else { return }
        policy.locked = locked
        dismissedForCurrentLock = false
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        policy.sessionActive = session?[kCGSessionOnConsoleKey as String] as? Bool ?? false
        policy.preview = false
        if locked { hide(); reconcile() }
        else { transitionToNotch() }
    }
    private func sleepChanged(_ asleep: Bool) {
        guard policy.asleep != asleep else { return }
        policy.asleep = asleep; visual.asleep = asleep
        spotify.setSuspended(asleep)
        onSleepChanged?(asleep)
        if asleep { hide() } else { reconcile() }
    }
    private func reconcile() {
        policy.enabled = UserDefaults.standard.bool(forKey: "enableLockScreenPlayer") && !IslandModules.shared.presentation
        if policy.shouldPresent && !dismissedForCurrentLock { show() }
        else if !visual.shrinking { hide() }
    }
    private func show() {
        guard window == nil, let screen = NSScreen.screens.first else { return }
        dismissal?.cancel()
        displayFrame = screen.frame
        visual.shrinking = false; visual.preview = policy.preview; visual.visible = false
        visual.locked = policy.locked; visual.artworkExpanded = false
        let panel = LockMediaPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.canBecomeVisibleWithoutLogin = policy.locked
        // Match SkyLightWindow's topmost level. The lower authentication area stays
        // transparent and the nonactivating panel never receives keyboard focus.
        panel.level = policy.locked ? NSWindow.Level(rawValue: Int(Int32.max - 2)) : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: LockScreenPlayerView(spotify: spotify, audio: audio, lyrics: lyrics, visual: visual, dismiss: { [weak self] in self?.dismissPreview() }))
        window = panel
        panel.orderFrontRegardless()
        if policy.locked && !lockSpace.attach(panel) {
            status = lockSpace.failure ?? "Lock-screen Space unavailable."
            hide()
            return
        }
        panel.orderFrontRegardless()
        inputTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateInputRegion() }
        }
        if let inputTimer { RunLoop.main.add(inputTimer, forMode: .common) }
        updateInputRegion()
        if policy.locked {
            // Lock notifications can arrive before loginwindow finishes ordering.
            // Retry a bounded number of times, not a permanent ordering loop.
            orderingTask = Task { @MainActor [weak self] in
                for delay: UInt64 in [150_000_000, 250_000_000, 450_000_000] {
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled, let self, self.policy.locked, !self.policy.asleep,
                          self.policy.sessionActive else { return }
                    self.window?.orderFrontRegardless()
                }
            }
        }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86)) { visual.visible = true }
        status = policy.locked ? "SkyLight overlay requested. Compatibility must be confirmed on this Mac." : "Desktop preview — this does not lock your Mac."
    }
    private func updateInputRegion() {
        guard let window, !visual.shrinking, !policy.asleep else { return }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - displayFrame.minX, y: displayFrame.maxY - mouse.y)
        let layout = LockPlayerLayout(size: displayFrame.size, locked: policy.locked)
        // Moving into the authentication area reveals the native prompt without
        // leaving a permanent hole in full-screen artwork. Never capture keys.
        if policy.locked && visual.artworkExpanded && layout.loginArea.contains(local) {
            withAnimation(.easeOut(duration: 0.18)) { visual.artworkExpanded = false }
        }
        // Continue an already-started slider drag. Never capture keyboard events.
        if NSEvent.pressedMouseButtons != 0 && !window.ignoresMouseEvents { return }
        window.ignoresMouseEvents = !layout.permitsInteraction(at: local, expanded: visual.artworkExpanded)
    }
    private func transitionToNotch() {
        guard var window = window else { return }
        // A window delegated to the special Space must not remain there during
        // the desktop transition. Replace its shell while retaining SwiftUI state.
        if visual.locked {
            let content = window.contentView
            window.contentView = nil
            window.orderOut(nil); window.close()
            lockSpace.hide()
            let desktop = LockMediaPanel(contentRect: displayFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            desktop.isOpaque = false; desktop.backgroundColor = .clear
            desktop.hasShadow = false; desktop.isReleasedWhenClosed = false
            desktop.hidesOnDeactivate = false; desktop.ignoresMouseEvents = true
            desktop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            desktop.contentView = content
            desktop.level = .floating; desktop.orderFrontRegardless()
            self.window = desktop; window = desktop
        }
        let target = notchRect()
        let enabled = UserDefaults.standard.object(forKey: "lockPlayerUnlockAnimation") as? Bool ?? true
        guard enabled, !policy.asleep, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              displayFrame.contains(CGPoint(x: target.midX, y: target.midY)) else { hide(); return }
        dismissal?.cancel()
        window.ignoresMouseEvents = true
        window.level = .floating
        visual.destination = CGPoint(x: target.midX - displayFrame.minX, y: displayFrame.maxY - target.midY)
        visual.notchSize = target.size
        withAnimation(.spring(response: 0.55, dampingFraction: 0.87)) { visual.shrinking = true }
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
    private func hide() {
        dismissal?.cancel(); dismissal = nil
        orderingTask?.cancel(); orderingTask = nil
        inputTimer?.invalidate(); inputTimer = nil
        window?.orderOut(nil); window?.close(); window = nil
        lockSpace.hide()
        visual.visible = false; visual.shrinking = false
    }
    func shutdown() {
        hide(); subscriptions.removeAll()
        observers.forEach { $0.0.removeObserver($0.1) }; observers.removeAll()
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributedObservers.removeAll()
    }
}

struct LockScreenPlayerView: View {
    @ObservedObject var spotify: SpotifyController
    @ObservedObject var audio: AudioCapture
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject var visual: LockVisualState
    let dismiss: () -> Void
    @AppStorage("lockPlayerLiquidGlass") private var liquidGlass = false
    @AppStorage("lockPlayerAmbientGlow") private var glow = true
    @AppStorage("lockPlayerSyncedLyrics") private var showLyrics = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var seeking = false
    @State private var seekValue = 0.0
    @State private var changingVolume = false
    @State private var volumeValue = 50.0
    private let motion = Animation.spring(response: 0.58, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { geometry in
            let layout = LockPlayerLayout(size: geometry.size, locked: visual.locked)
            let controls = layout.controls
            let expanded = visual.artworkExpanded && !visual.shrinking
            ZStack(alignment: .topLeading) {
                if glow && !reduceTransparency && !visual.asleep {
                    LinearGradient(colors: spotify.ambientColors.map { Color(nsColor: $0).opacity(expanded ? 0.6 : visual.locked ? 0 : 0.2) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .opacity(visual.shrinking ? 0 : 1).allowsHitTesting(false)
                }
                if expanded {
                    // A backing copy carries the aspect-fill image. The thumbnail
                    // itself animates below, preserving a continuous shared origin.
                    Color.black.opacity(0.15).allowsHitTesting(false)
                }
                if visual.preview {
                    previewClock
                        .frame(width: geometry.size.width)
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.18)
                        .opacity(visual.shrinking ? 0 : 1)
                        .zIndex(2)
                }
                if expanded {
                    CoverArt(artwork: spotify.artwork)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay {
                            LinearGradient(colors: [.black.opacity(0.25), .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { toggleArtwork() }
                        .accessibilityLabel("Collapse full-screen artwork")
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 1.035)))
                        .zIndex(0)
                }
                ZStack {
                    if visual.shrinking {
                        RoundedRectangle(cornerRadius: 10).fill(.black)
                    } else {
                        PlayerView(spotify: spotify, audio: audio, openLibrarySettings: {}, artworkAction: toggleArtwork, locked: visual.locked, hideArtwork: expanded)
                            .frame(width: controls.width, height: controls.height - 24)
                            .padding(.vertical, 12)
                            .background { lockCardSurface }
                            .overlay {
                                if liquidGlass && !reduceTransparency {
                                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                                        .stroke(.white.opacity(0.22), lineWidth: 0.6)
                                        .allowsHitTesting(false)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                            .contextMenu {
                                Button(visual.artworkExpanded ? "Collapse artwork" : "Expand artwork", action: toggleArtwork)
                                Button("Hide player", action: dismiss)
                                Button("Volume down") { spotify.setVolume(max(0, spotify.volume - 10)) }
                                Button("Volume up") { spotify.setVolume(min(100, spotify.volume + 10)) }
                            }
                    }
                }
                .frame(width: visual.shrinking ? visual.notchSize.width : controls.width,
                       height: visual.shrinking ? visual.notchSize.height : controls.height)
                .position(visual.shrinking ? visual.destination : CGPoint(x: controls.midX, y: controls.midY))
                .shadow(color: .black.opacity(0.24), radius: visual.shrinking ? 0 : 22, y: 10)
                .zIndex(3)
                if showLyrics && expanded && !visual.shrinking {
                    lyricLine
                        .frame(width: controls.width)
                        .position(x: controls.midX, y: max(40, controls.minY - 44))
                        .zIndex(3)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .opacity(visual.visible ? 1 : 0)
            .animation(reduceMotion ? .easeInOut(duration: 0.18) : motion, value: visual.artworkExpanded)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }
    @ViewBuilder private var lockCardSurface: some View {
        if !liquidGlass || reduceTransparency {
            Color.black
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }
    private var previewClock: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 2) {
                Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                Text(context.date, style: .time)
                    .font(.system(size: 86, weight: .semibold, design: .rounded)).monospacedDigit()
            }.shadow(color: .black.opacity(0.2), radius: 12, y: 2)
        }.allowsHitTesting(false)
    }
    private var lyricLine: some View {
        let lines = lyrics.tracks[spotify.trackID] ?? []
        let index = LRCParser.activeIndex(in: lines, position: spotify.position)
        return Text(index.map { lines[$0].text } ?? (lines.isEmpty ? "Import timed lyrics in Settings" : "♪"))
            .font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(2).multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.8), radius: 6, y: 2)
            .id(index).transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
            .animation(reduceMotion || visual.asleep ? nil : .easeInOut(duration: 0.3), value: index)
    }
    private func toggleArtwork() {
        guard !visual.shrinking else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : motion) { visual.artworkExpanded.toggle() }
    }
    private func transport(_ symbol: String, _ label: String, size: CGFloat = 21, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: size)).frame(width: 40, height: 38) }
            .buttonStyle(SpringControlStyle()).disabled(!spotify.connected).accessibilityLabel(label)
    }
    private func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

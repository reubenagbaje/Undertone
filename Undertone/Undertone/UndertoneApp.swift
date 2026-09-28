import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum IslandMotion {
    static var strength: Double { min(1.5, max(0, UserDefaults.standard.object(forKey: "animationIntensity") as? Double ?? 1)) }
    static func spring(_ response: Double, _ damping: Double, _ blend: Double) -> Animation {
        if strength == 0 { return .linear(duration: 0.01) }
        return .interactiveSpring(response: response * (0.8 + strength * 0.2), dampingFraction: min(1, damping + (1 - strength) * 0.15), blendDuration: blend)
    }
    static var swipeReturn: Animation { spring(0.34, 0.8, 0.12) }
    static var finger: Animation { spring(0.12, 0.86, 0.08) }
    static var morph: Animation { spring(0.4, 0.86, 0.16) }
    static var retract: Animation { spring(0.32, 0.92, 0.14) }
    static var preview: Animation { spring(0.36, 0.88, 0.14) }
    static var hover: Animation { spring(0.28, 0.86, 0.14) }
    static var cover: Animation { spring(0.36, 0.84, 0.14) }
}

@main struct UndertoneApp: App {
    @NSApplicationDelegateAdaptor(IslandDelegate.self) private var delegate
    var body: some Scene {
        Settings { SettingsDashboard(state: delegate.state, spotify: delegate.spotify, audio: delegate.audio, lockPlayer: delegate.lockPlayer) }
            .commands {
                CommandMenu("Player") {
                    Button("Show Player") { delegate.showPlayer() }.keyboardShortcut("o")
                    Button("Collapse Player") { delegate.collapsePlayer() }
                    Button("Toggle Presentation Mode") { IslandModules.shared.presentation.toggle() }.keyboardShortcut("p", modifiers: [.command, .option])
                }
            }
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // A borderless island must be allowed into the display's camera/menu-bar strip.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor final class IslandState: ObservableObject {
    @Published var dynamicIsland = UserDefaults.standard.bool(forKey: "dynamicIsland") {
        didSet { UserDefaults.standard.set(dynamicIsland, forKey: "dynamicIsland") }
    }
    @Published var islandGap = min(80, max(8, UserDefaults.standard.object(forKey: "islandGap") as? Double ?? 12)) {
        didSet { UserDefaults.standard.set(islandGap, forKey: "islandGap"); UserDefaults.standard.set(islandGap, forKey: "islandGap." + selectedDisplay) }
    }
    @Published var alwaysShowNotch = UserDefaults.standard.bool(forKey: "alwaysShowNotch") {
        didSet { UserDefaults.standard.set(alwaysShowNotch, forKey: "alwaysShowNotch") }
    }
    @Published var toolsOpen = false
    @Published var timerActive = false
    @Published var timerFocused = true
    @Published var fileDragHover = false
    @Published var moduleNotice: String?
    @Published var moduleSymbol = "timer"
    @Published var selectedDisplay = UserDefaults.standard.string(forKey: "selectedDisplay") ?? "auto" {
        didSet { UserDefaults.standard.set(selectedDisplay, forKey: "selectedDisplay") }
    }
    @Published var appearancePreset = UserDefaults.standard.string(forKey: "appearancePreset") ?? "Compact" {
        didSet { UserDefaults.standard.set(appearancePreset, forKey: "appearancePreset") }
    }
    @Published var queueOpen = false
    @Published var levelKind: String?
    @Published var levelValue: Double = 0
    @Published var expanded = false
    @Published var previewing = false
    @Published var playbackActive = false
    @Published var trackNotice: String?
    @Published var swipeProgress: CGFloat = 0
    @Published var swipeEngaged = false
    @Published var swipeTracking = false
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    @Published var expandedHeight: CGFloat = 157
    @Published var expandedWidth: CGFloat = 398
    @Published var pinned = false
    @Published var settingsOpen = false
    @Published var haptics = UserDefaults.standard.object(forKey: "hoverHaptics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(haptics, forKey: "hoverHaptics") }
    }
    @Published var idleCornerCurve = min(16, max(0, UserDefaults.standard.object(forKey: "idleCornerCurve") as? Double ?? 6)) {
        didSet { UserDefaults.standard.set(idleCornerCurve, forKey: "idleCornerCurve") }
    }
    @Published var glassAppearance = UserDefaults.standard.bool(forKey: "glassAppearance") {
        didSet { UserDefaults.standard.set(glassAppearance, forKey: "glassAppearance") }
    }
    @Published var whiteOutline = UserDefaults.standard.bool(forKey: "whiteOutline") {
        didSet { UserDefaults.standard.set(whiteOutline, forKey: "whiteOutline") }
    }
    @Published var reverseSwipes = UserDefaults.standard.bool(forKey: "reverseSwipes") {
        didSet { UserDefaults.standard.set(reverseSwipes, forKey: "reverseSwipes") }
    }
    var dormant: Bool { !timerActive && !playbackActive && !previewing && !expanded && trackNotice == nil && levelKind == nil && moduleNotice == nil }
    var wingWidth: CGFloat { trackNotice != nil ? 44 : (previewing || swipeEngaged) ? 46 : 34 }
    var swipeVisual: SwipePresentation { SwipePresentation(progress: Double(swipeProgress), reversed: reverseSwipes) }
    var swipeExtension: CGFloat { expanded ? 0 : CGFloat(swipeVisual.extensionWidth) }
    var shellOffset: CGFloat { CGFloat(swipeVisual.forward ? 1 : -1) * swipeExtension / 2 }
    var shoulder: CGFloat { dynamicIsland ? 0 : expanded ? 19 : (levelKind != nil || moduleNotice != nil) ? max(12, CGFloat(idleCornerCurve)) : CGFloat(idleCornerCurve) }
    var bottomCornerRadius: CGFloat { expanded ? 50 : (levelKind != nil || moduleNotice != nil) ? 28 : trackNotice == nil ? 17 : 24 }
    var compactWidth: CGFloat { timerActive ? notchWidth + 148 + shoulder * 2 : notchWidth + wingWidth * 2 + shoulder * 2 + (dynamicIsland ? 20 : 0) }
    var compactHeight: CGFloat { notchHeight + (previewing || swipeEngaged || trackNotice != nil ? 2 : 1) }
    var visibleWidth: CGFloat { expanded ? expandedWidth : levelKind != nil ? max(280, notchWidth + 32) : timerActive ? compactWidth : moduleNotice != nil ? max(280, notchWidth + 32) : dormant ? notchWidth : compactWidth + swipeExtension }
    var visibleHeight: CGFloat { expanded ? (timerActive && timerFocused && !toolsOpen && !queueOpen ? 132 : expandedHeight) + notchHeight + ((queueOpen || toolsOpen) ? 280 : 0) + (levelKind == nil ? 0 : 76) : levelKind != nil ? notchHeight + 72 : timerActive ? compactHeight : moduleNotice != nil ? notchHeight + 44 : dormant ? notchHeight : compactHeight + (trackNotice == nil || timerActive ? 0 : 36) }
    func open() {
        guard !expanded else { return }
        if haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : IslandMotion.morph) { expanded = true }
    }
    func close() {
        pinned = false
        queueOpen = false
        toolsOpen = false
        timerFocused = true
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : IslandMotion.retract) { expanded = false }
    }
}

@MainActor final class IslandDelegate: NSObject, NSApplicationDelegate {
    let spotify = SpotifyController()
    let audio = AudioCapture()
    let state = IslandState()
    lazy var lockPlayer = LockScreenPlayerController(spotify: spotify, audio: audio, notchRect: { [weak self] in
        guard let self else { return .zero }
        return CGRect(x: self.anchor.x - self.state.compactWidth / 2, y: self.anchor.y - self.state.compactHeight, width: self.state.compactWidth, height: self.state.compactHeight)
    })
    private let shortcuts = PlayerShortcuts()
    private let deviceLevels = DeviceControls()
    private var levelSampleTime: TimeInterval = 0
    private var levelDeadline: TimeInterval = 0
    private var previousVolume: Double?
    private var previousBrightness: Double?
    private var previousDisplay = ""
    private var lastDisplay = ""
    private var lastPreset = ""
    private var lastIslandStyle = false
    private var lastIslandGap: Double = -1
    private var shortcutObserver: NSObjectProtocol?
    private var panel: IslandPanel?
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var leaveTime: Date?
    private var anchor = CGPoint.zero
    private var hoverIntent = HoverIntent()
    private var peekIntent = HoverIntent()
    private var swipeIntent = SwipeIntent()
    private var eventMonitor: Any?
    private var suppressHoverUntilExit = false
    private var lastSwipeEvent: TimeInterval = 0
    private var swipeSettleTask: Task<Void, Never>?
    private var phaseLessSwipe = false
    private var fileDragIntent = FileDragIntent()
    private var lastTrackRevision = 0
    private var notice = TrackNoticeIntent()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        shortcuts.action = { [weak self] id in
            guard let self else { return }
            switch id {
            case 1: self.state.expanded ? self.collapsePlayer() : self.showPlayer()
            case 2: self.spotify.command(.toggle)
            case 3: self.spotify.command(.next)
            case 4: self.spotify.restartOrPrevious()
            case 5: if self.spotify.playerSource == "Spotify" { Task { await self.spotify.library.toggleCurrent() } }
            case 6:
                let defaults = UserDefaults.standard
                defaults.set(!defaults.bool(forKey: "enableLockScreenPlayer"), forKey: "enableLockScreenPlayer")
            case 7: IslandModules.shared.presentation.toggle()
            default: break
            }
        }
        IslandModules.shared.start()
        _ = AppUpdates.shared
        NotchVolumeKeys.shared.onLevel = { [weak self] kind, value in
            guard let self else { return }
            self.state.levelKind = kind; self.state.levelValue = value
            self.levelDeadline = ProcessInfo.processInfo.systemUptime + 1.6
        }
        NotchVolumeKeys.shared.configure()
        shortcuts.start()
        shortcutObserver = NotificationCenter.default.addObserver(forName: .init("UndertoneShortcutPreferenceChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.shortcuts.start() }
        }
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: IslandView(state: state, spotify: spotify, audio: audio))
        self.panel = panel
        position()
        panel.orderFrontRegardless()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.position() }
        }
        // Reading pointer position requires no Accessibility/Input Monitoring permission.
        // Only the visible island accepts clicks; the clear canvas is click-through.
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePointer() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        spotify.startAutomaticConnection()
        lockPlayer.onSleepChanged = { [weak self] asleep in
            guard let self else { return }
            self.timer?.fireDate = asleep ? .distantFuture : Date()
            self.audio.setDisplaySleeping(asleep)
            IslandModules.shared.setSleeping(asleep)
            self.previousVolume = nil; self.previousBrightness = nil
            self.state.levelKind = nil
        }
        lockPlayer.start()
        Task { await audio.resumeIfEnabled() }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event)
        }
    }

    func showPlayer() { IslandModules.shared.presentation = false; state.pinned = true; state.open() }
    func collapsePlayer() { state.close() }
    func showSettings() { state.settingsOpen = true }

    private func position() {
        guard let screen = NSScreen.screens.first(where: { $0.undertoneID == state.selectedDisplay }) ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first,
              let panel else { return }
        if lastDisplay != state.selectedDisplay {
            lastDisplay = state.selectedDisplay
            state.islandGap = min(80, max(8, UserDefaults.standard.object(forKey: "islandGap." + state.selectedDisplay) as? Double ?? 12))
        }
        lastPreset = state.appearancePreset
        let inset = screen.safeAreaInsets.top
        lastIslandStyle = state.dynamicIsland
        lastIslandGap = state.islandGap
        if state.dynamicIsland {
            state.notchWidth = 104
            state.notchHeight = 40
            let menuInset = max(inset, max(24, screen.frame.maxY - screen.visibleFrame.maxY))
            anchor = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - menuInset - state.islandGap)
        } else if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.notchWidth = max(1, right.minX - left.maxX)
            state.notchHeight = inset
            anchor = CGPoint(x: (left.maxX + right.minX) / 2, y: screen.frame.maxY)
        } else {
            state.notchWidth = 180
            state.notchHeight = 30
            anchor = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
        }
        let preferredWidth: CGFloat = state.appearancePreset == "Comfortable" ? 438 : state.appearancePreset == "Minimal" ? 350 : 398
        state.expandedWidth = max(preferredWidth, state.notchWidth + 208)
        state.expandedHeight = (state.expandedWidth - 38) / 360 * 189 - state.notchHeight
        let size = CGSize(width: state.expandedWidth + 40, height: state.expandedHeight + state.notchHeight + 48 + 356)
        panel.setFrame(NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height, width: size.width, height: size.height + (state.dynamicIsland ? 12 : 0)), display: true)
    }

    private func updatePointer() {
        guard let panel else { return }
        if state.dynamicIsland != lastIslandStyle || state.islandGap != lastIslandGap || state.selectedDisplay != lastDisplay || state.appearancePreset != lastPreset { position() }
        if IslandModules.shared.presentation {
            panel.orderOut(nil); return
        } else if !panel.isVisible { panel.orderFrontRegardless() }
        if spotify.playerSource != "Spotify" { state.queueOpen = false }
        let modules = IslandModules.shared
        if state.timerActive != modules.timerActive { state.timerActive = modules.timerActive }
        if state.moduleNotice != modules.activity { state.moduleNotice = modules.activity }
        if state.moduleSymbol != modules.activitySymbol { state.moduleSymbol = modules.activitySymbol }
        let playback = spotify.connected && spotify.playing
        if state.playbackActive != playback { state.playbackActive = playback }
        let now = ProcessInfo.processInfo.systemUptime
        // Read actual levels after macOS handles media keys; no keyboard interception.
        if now - levelSampleTime > 0.5 {
            levelSampleTime = now
            deviceLevels.refresh()
            if deviceLevels.volumeAvailable, let old = previousVolume, abs(old - deviceLevels.volume) > 0.002 {
                state.levelKind = "Volume"; state.levelValue = deviceLevels.volume; levelDeadline = now + 1.6
            }
            if deviceLevels.brightnessAvailable, previousDisplay == deviceLevels.displayName, let old = previousBrightness, abs(old - deviceLevels.brightness) > 0.002 {
                state.levelKind = "Brightness"; state.levelValue = deviceLevels.brightness; levelDeadline = now + 1.6
            }
            previousVolume = deviceLevels.volumeAvailable ? deviceLevels.volume : nil
            previousBrightness = deviceLevels.brightnessAvailable ? deviceLevels.brightness : nil
            previousDisplay = deviceLevels.displayName
        }
        if state.levelKind != nil && now > levelDeadline { state.levelKind = nil }
        if spotify.trackRevision != lastTrackRevision {
            lastTrackRevision = spotify.trackRevision
            if state.playbackActive && !state.expanded {
                notice.show("\(spotify.artist) • \(spotify.title)", now: now)
            }
        }
        notice.update(now: now, dismiss: state.expanded || state.timerActive || !spotify.connected)
        if state.trackNotice != notice.text { state.trackNotice = notice.text }
        let width = state.visibleWidth
        let height = state.visibleHeight + (state.dormant ? 3 : 0)
        let rect = NSRect(x: anchor.x + state.shellOffset - width / 2, y: anchor.y - height, width: width, height: height)
        let pointer = NSEvent.mouseLocation
        let inside = NotchHitTarget.contains(pointer, in: rect)
        let dragBoard = NSPasteboard(name: .drag)
        let fileDrag = fileDragIntent.update(change: dragBoard.changeCount, buttonDown: NSEvent.pressedMouseButtons != 0, containsFiles: NSEvent.pressedMouseButtons != 0 && dragBoard.types?.contains(.fileURL) == true)
        let dragHover = fileDrag && inside && IslandModules.shared.shelfEnabled
        if state.fileDragHover != dragHover { state.fileDragHover = dragHover }
        if state.fileDragHover {
            IslandModules.shared.selectedTab = 1
            state.queueOpen = false; state.toolsOpen = true; state.open()
        }
        // The tiny idle activation strip is pointer-tracked but remains click-through.
        panel.ignoresMouseEvents = (!inside && !swipeIntent.active) || (state.dormant && !state.fileDragHover)
        if !inside, !swipeIntent.active {
            suppressHoverUntilExit = false
        }
        if phaseLessSwipe && swipeIntent.active && now - lastSwipeEvent > 0.25 {
            _ = swipeIntent.finish(cancelled: true)
            settleSwipe(committed: false)
        }
        // Fixed physical camera target includes the screen's top edge. Preview
        // growth must neither steal this target nor enlarge it under the pointer.
        let cameraTarget = NSRect(x: anchor.x - state.notchWidth / 2,
                                  y: anchor.y - state.notchHeight - 4,
                                  width: state.notchWidth, height: state.notchHeight + 4)
        let canExpand = state.expanded || (state.dynamicIsland ? inside : NotchHitTarget.contains(pointer, in: cameraTarget))
        let shouldOpen = hoverIntent.update(inside: inside && canExpand && !suppressHoverUntilExit, now: now)
        _ = peekIntent.update(inside: inside && !suppressHoverUntilExit, now: now)
        let preview = peekIntent.previewing || (inside && suppressHoverUntilExit)
        if state.previewing != preview { state.previewing = preview }
        if inside {
            leaveTime = nil
            if shouldOpen { state.open() }
        } else if state.expanded, !state.pinned, !state.settingsOpen, !spotify.quickControlsOpen, NSEvent.pressedMouseButtons == 0 {
            if leaveTime == nil { leaveTime = Date() }
            if let leaveTime, Date().timeIntervalSince(leaveTime) > 0.45 {
                state.close()
                self.leaveTime = nil
            }
        }
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, !state.settingsOpen, !state.queueOpen, !state.toolsOpen, event.hasPreciseScrollingDeltas else { return event }
        let now = ProcessInfo.processInfo.systemUptime
        // Filter out scrolls on the transparent canvas and on settings popovers.
        let width = state.visibleWidth
        let height = state.visibleHeight + (state.dormant ? 3 : 0)
        let hit = NSRect(x: anchor.x + state.shellOffset - width / 2, y: anchor.y - height, width: width, height: height)
        guard NotchHitTarget.contains(NSEvent.mouseLocation, in: hit) || swipeIntent.active else { return event }
        let isMomentum = !event.momentumPhase.isEmpty
        let began = event.phase.contains(.began) || (event.phase.isEmpty && now - lastSwipeEvent > 0.25)
        // With natural scrolling, delta follows fingers; normalize the other mode.
        let sign = event.isDirectionInvertedFromDevice ? 1.0 : -1.0
        if began && !isMomentum {
            swipeSettleTask?.cancel()
            phaseLessSwipe = event.phase.isEmpty
        }
        let wasClaimed = swipeIntent.claimed
        swipeIntent.consume(dx: Double(event.scrollingDeltaX) * sign,
                            dy: Double(event.scrollingDeltaY) * sign,
                            began: began, momentum: isMomentum)
        lastSwipeEvent = now
        let ownsGesture = wasClaimed || swipeIntent.claimed
        if ownsGesture {
            suppressHoverUntilExit = true
            _ = hoverIntent.update(inside: false, now: now)
            _ = peekIntent.update(inside: false, now: now)
            state.previewing = false
            state.swipeEngaged = true
            state.swipeTracking = true
            if state.expanded { state.close() }
            state.swipeProgress = CGFloat(swipeIntent.visualTravel)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let direction = swipeIntent.finish(cancelled: event.phase.contains(.cancelled))
            settleSwipe(committed: direction != nil)
            if let direction {
                if state.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                if direction.skipsForward(reversed: state.reverseSwipes) { spotify.command(.next) }
                else { spotify.restartOrPrevious() }
            }
        }
        if ownsGesture || (isMomentum && suppressHoverUntilExit) { return nil }
        return event
    }

    private func settleSwipe(committed: Bool) {
        state.swipeTracking = false
        swipeSettleTask?.cancel()
        swipeSettleTask = Task { @MainActor in
            if committed { try? await Task.sleep(nanoseconds: 160_000_000) }
            guard !Task.isCancelled else { return }
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : IslandMotion.retract) {
                state.swipeProgress = 0
            }
            try? await Task.sleep(nanoseconds: committed ? 440_000_000 : 340_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : IslandMotion.hover) {
                state.swipeEngaged = false
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotchVolumeKeys.shared.stop()
        IslandModules.shared.stop()
        shortcuts.stop()
        if let shortcutObserver { NotificationCenter.default.removeObserver(shortcutObserver) }
        swipeSettleTask?.cancel()
        timer?.invalidate()
        lockPlayer.shutdown()
        spotify.shutdown()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}

// Flush top edge and rounded lower corners merge the black wings into the camera housing.
struct IslandShape: Shape {
    var shoulder: CGFloat = 0
    var bottomRadius: CGFloat = 52
    var openTop = false
    var floating = false
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottomRadius) }
        set { shoulder = newValue.first; bottomRadius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        if floating {
            return RoundedRectangle(cornerRadius: min(rect.height / 2, 38), style: .continuous).path(in: rect)
        }
        let inset = max(0, shoulder)
        let left = rect.minX + inset
        let right = rect.maxX - inset
        let radius = min(bottomRadius, (rect.height - inset) / 2)
        var path = Path()
        path.move(to: CGPoint(x: openTop ? rect.maxX : rect.minX, y: rect.minY))
        if !openTop { path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)) }
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + inset), control: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - radius))
        path.addCurve(to: CGPoint(x: right - radius, y: rect.maxY),
                      control1: CGPoint(x: right, y: rect.maxY - radius * 0.4),
                      control2: CGPoint(x: right - radius * 0.4, y: rect.maxY))
        path.addLine(to: CGPoint(x: left + radius, y: rect.maxY))
        path.addCurve(to: CGPoint(x: left, y: rect.maxY - radius),
                      control1: CGPoint(x: left + radius * 0.4, y: rect.maxY),
                      control2: CGPoint(x: left, y: rect.maxY - radius * 0.4))
        path.addLine(to: CGPoint(x: left, y: rect.minY + inset))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: left, y: rect.minY))
        if !openTop { path.closeSubpath() }
        return path
    }
}

struct IslandView: View {
    @ObservedObject private var modules = IslandModules.shared
    @ObservedObject var state: IslandState
    @ObservedObject var spotify: SpotifyController
    @ObservedObject var audio: AudioCapture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settingsHovered = false
    @State private var leftHovered = false
    @State private var rightHovered = false
    private var swipe: SwipePresentation { state.swipeVisual }
    private var leftFeedback: Bool { !state.swipeEngaged && (leftHovered || (spotify.feedbackSymbol != nil && spotify.skipDirection < 0)) }
    private var rightFeedback: Bool { !state.swipeEngaged && (rightHovered || (spotify.feedbackSymbol != nil && spotify.skipDirection > 0)) }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if !state.expanded, let kind = state.levelKind {
                    Color.clear.frame(height: state.notchHeight)
                    NotchLevelView(kind: kind, value: state.levelValue, expanded: false).frame(height: 72)
                } else if !state.expanded, modules.timerActive {
                    HStack(spacing: 0) {
                        CompactTimerSymbol().frame(width: 74)
                        Color.clear.frame(width: state.notchWidth)
                        Text(modules.timerText).font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.orange).frame(width: 74)
                    }.frame(height: state.compactHeight)
                        .contentShape(Rectangle()).onTapGesture { state.timerFocused = true; state.open() }
                } else if state.expanded && modules.timerActive && state.timerFocused && !state.toolsOpen && !state.queueOpen {
                    VStack(spacing: 8) {
                        Color.clear.frame(height: state.notchHeight)
                        LiveTimerCard().padding(.horizontal, 28).frame(height: 64)
                        HStack {
                            Button("Music") { withAnimation(reduceMotion ? nil : IslandMotion.morph) { state.timerFocused = false } }
                            Spacer()
                            if modules.hasTools { Button("Tools") { state.toolsOpen = true } }
                        }.font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).buttonStyle(IslandToolButtonStyle()).padding(.horizontal, 28).padding(.bottom, 16)
                    }
                    if let kind = state.levelKind { NotchLevelView(kind: kind, value: state.levelValue, expanded: true).frame(height: 76) }
                } else if !state.expanded, let notice = state.moduleNotice {
                    Color.clear.frame(height: state.notchHeight)
                    Label(notice, systemImage: state.moduleSymbol).font(.system(size: 12, weight: .semibold)).lineLimit(1).padding(.horizontal, 28).frame(height: 44)
                } else if state.expanded {
                    PlayerView(spotify: spotify, audio: audio, openLibrarySettings: { state.settingsOpen = true }, queueAction: { withAnimation(reduceMotion ? nil : IslandMotion.morph) { state.toolsOpen = false; state.queueOpen.toggle() } }, queueActive: state.queueOpen, toolsAction: { withAnimation(reduceMotion ? nil : IslandMotion.morph) { state.queueOpen = false; state.toolsOpen.toggle() } })
                        .frame(height: state.expandedHeight + state.notchHeight, alignment: .top)
                        .overlay(alignment: .topTrailing) {
                            Button { state.settingsOpen = true } label: {
                                Image(systemName: "ellipsis").font(.system(size: 10, weight: .semibold))
                                    .frame(width: 26, height: 20)
                            }
                            .buttonStyle(.plain).foregroundStyle(Color(white: 0.55))
                            .opacity(settingsHovered || state.settingsOpen ? 1 : 0)
                            .onHover { settingsHovered = $0 }
                            .help("Setup and settings").accessibilityLabel("Setup and settings")
                            .padding(.trailing, 22).padding(.top, 2)

                        }
                        .contextMenu { Button("Settings…") { state.settingsOpen = true } }
                        .transition(.opacity)
                    if let kind = state.levelKind { NotchLevelView(kind: kind, value: state.levelValue, expanded: true).frame(height: 76) }
                    if state.toolsOpen { IslandToolsView().frame(height: 280).transition(.opacity) }
                    if state.queueOpen {
                        NotchQueueView(spotify: spotify, library: spotify.library)
                            .frame(height: 280).transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } else {
                    HStack(spacing: 0) {
                        Button { spotify.command(.toggle) } label: {
                            ZStack {
                                AnimatedCover(spotify: spotify, compact: true)
                                    .frame(width: max(18, state.notchHeight - 12), height: max(18, state.notchHeight - 12))
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .blur(radius: reduceMotion ? 0 : swipe.reveal * 4)
                                    .opacity(leftFeedback ? 0 : swipe.coverOpacity)
                                Image(systemName: "backward.end.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .opacity(swipe.backwardReveal)
                                    .blur(radius: reduceMotion ? 0 : 2 * (1 - swipe.backwardReveal))
                                    .offset(x: reduceMotion ? 0 : swipe.backwardIconOffset)
                                if leftFeedback {
                                    Image(systemName: spotify.skipDirection < 0 ? (spotify.feedbackSymbol ?? (spotify.playing ? "pause.fill" : "play.fill")) : (spotify.playing ? "pause.fill" : "play.fill"))
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }.frame(width: state.wingWidth, height: state.compactHeight)
                        }
                        .buttonStyle(.plain).foregroundStyle(.white).disabled(!spotify.connected)
                        .onHover { leftHovered = $0 }.help(spotify.playing ? "Pause" : "Play")
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: leftHovered)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: spotify.feedbackSymbol)
                        .accessibilityLabel(spotify.playing ? "Pause" : "Play")
                        Color.clear.frame(width: state.notchWidth).contentShape(Rectangle())
                            .onTapGesture { state.open() }
                        Button { spotify.command(.next) } label: {
                            ZStack {
                                Waveform(levels: audio.levels, tint: Color(nsColor: spotify.waveformTint), maximumBarWidth: 2.25)
                                    .frame(width: 16, height: 16)
                                    .blur(radius: reduceMotion ? 0 : swipe.forwardReveal * 4)
                                    .opacity(rightFeedback ? 0 : 1 - swipe.forwardReveal)
                                    .offset(x: reduceMotion ? 0 : swipe.forwardAmount * 6)
                                Image(systemName: "forward.end.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .opacity(swipe.forwardReveal)
                                    .blur(radius: reduceMotion ? 0 : 3 * (1 - swipe.forwardReveal))
                                    .offset(x: reduceMotion ? 0 : swipe.forwardIconOffset)
                                if rightFeedback {
                                    Image(systemName: spotify.skipDirection > 0 ? (spotify.feedbackSymbol ?? "forward.fill") : "forward.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }.frame(width: state.wingWidth, height: state.compactHeight)
                        }
                        .buttonStyle(.plain).foregroundStyle(.white).disabled(!spotify.connected)
                        .onHover { rightHovered = $0 }.help("Next track").accessibilityLabel("Next track")
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: rightHovered)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: spotify.feedbackSymbol)
                    }
                    .frame(height: state.compactHeight)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Undertone notch. Expand music player")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { state.open() }
                    TrackNoticeCaption(text: state.trackNotice, width: state.compactWidth, library: spotify.library)
                        .frame(height: state.trackNotice == nil ? 0 : 36, alignment: .top)
                        .clipped()

                }
            }
            .offset(x: -state.shellOffset)
            .frame(width: state.visibleWidth,
                   height: state.visibleHeight,
                   alignment: .top)
            .background {
                IslandSurface(glass: state.glassAppearance && state.expanded, shoulder: state.shoulder, floating: state.dynamicIsland)
                    .overlay(alignment: .bottom) {
                        if UserDefaults.standard.bool(forKey: "artworkAccent") && state.expanded {
                            LinearGradient(colors: [.clear, Color(nsColor: spotify.waveformTint).opacity(0.16)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                        }
                    }
            }
            .clipShape(IslandShape(shoulder: state.shoulder, bottomRadius: state.bottomCornerRadius, floating: state.dynamicIsland))
            .overlay {
                if state.whiteOutline {
                    IslandShape(shoulder: state.shoulder, bottomRadius: state.bottomCornerRadius, openTop: !state.dynamicIsland, floating: state.dynamicIsland).stroke(.white.opacity(0.65), lineWidth: 0.75)
                        .padding(0.375).allowsHitTesting(false)
                }
            }
            .onChange(of: modules.hasTools) { enabled in if !enabled { state.toolsOpen = false } }
            .onChange(of: modules.timerActive) { active in state.timerActive = active; if active { state.timerFocused = true } }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: Binding(get: { state.fileDragHover }, set: { targeted in
                state.fileDragHover = targeted && modules.shelfEnabled && !modules.presentation
                if state.fileDragHover { modules.selectedTab = 1; state.queueOpen = false; state.toolsOpen = true; state.open() }
            })) { providers in
                guard modules.shelfEnabled, !modules.presentation else { return false }
                modules.selectedTab = 1
                state.queueOpen = false; state.toolsOpen = true; state.open()
                return IslandModules.shared.accept(providers)
            }
            .offset(x: state.shellOffset)
            .opacity(state.dormant && !state.alwaysShowNotch ? 0 : 1)
            .shadow(color: .black.opacity(state.expanded ? 0.32 : 0.22), radius: state.expanded ? 14 : 5, y: state.expanded ? 7 : 3)
            .animation(reduceMotion ? nil : state.swipeTracking ? IslandMotion.finger : IslandMotion.swipeReturn, value: state.swipeProgress)
            .animation(reduceMotion ? nil : IslandMotion.hover, value: state.swipeEngaged)
            .animation(reduceMotion ? nil : state.expanded ? IslandMotion.morph : IslandMotion.retract, value: state.expanded)
            .animation(reduceMotion ? nil : IslandMotion.morph, value: state.queueOpen)
            .animation(reduceMotion ? nil : IslandMotion.morph, value: state.toolsOpen)
            .animation(reduceMotion ? nil : IslandMotion.morph, value: state.timerActive)
            .animation(reduceMotion ? nil : IslandMotion.morph, value: state.timerFocused)
            .animation(reduceMotion ? nil : IslandMotion.preview, value: state.moduleNotice)
            .animation(reduceMotion ? nil : IslandMotion.morph, value: state.levelKind)
            .animation(reduceMotion ? nil : IslandMotion.hover, value: state.previewing)
            .animation(reduceMotion ? nil : IslandMotion.hover, value: state.idleCornerCurve)
            .animation(reduceMotion ? nil : IslandMotion.preview, value: state.glassAppearance)
            .animation(reduceMotion ? nil : IslandMotion.morph, value: state.playbackActive)
            .animation(reduceMotion ? nil : state.trackNotice == nil ? IslandMotion.retract : IslandMotion.preview, value: state.trackNotice)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, state.dynamicIsland ? 12 : 0)
        .overlay { SettingsRequestHandler(state: state) }
        .preferredColorScheme(.dark).ignoresSafeArea()
    }
}

// Glass is behind the controls, with an opaque camera region and a smooth
// fade ending halfway down. Older systems use native translucent material.
struct IslandSurface: View {
    let glass: Bool
    let shoulder: CGFloat
    var floating = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if glass && !reduceTransparency {
            ZStack {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.regular, in: IslandShape(shoulder: shoulder, bottomRadius: 46, floating: floating))
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.18),
                    .init(color: .black.opacity(0.8), location: 0.3),
                    .init(color: .black.opacity(0.25), location: 0.45),
                    .init(color: .clear, location: 0.58)
                ], startPoint: .top, endPoint: .bottom)
            }
        } else { Color.black }
    }
}

struct SpringControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverControl(isPressed: configuration.isPressed) { configuration.label }
    }
}

struct HoverControl<Content: View>: View {
    let isPressed: Bool
    @ViewBuilder let content: () -> Content
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        content()
            .background {
                Circle().fill(.white.opacity(enabled && (hovered || isPressed) ? (isPressed ? 0.2 : 0.11) : 0))
                    .frame(width: 38, height: 38)
                    .scaleEffect(hovered || isPressed ? 1 : 0.78)
            }
            .contentShape(Circle())
            .scaleEffect(enabled && !reduceMotion ? (isPressed ? 0.84 : hovered ? 1.1 : 1) : 1)
            .offset(y: enabled && hovered && !isPressed && !reduceMotion ? -1 : 0)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.38, dampingFraction: 0.66, blendDuration: 0.12), value: isPressed)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.38, dampingFraction: 0.72, blendDuration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}

struct CoverDissolve: AnimatableModifier {
    var amount: Double
    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }
    func body(content: Content) -> some View {
        content.scaleEffect(1 - amount * 0.18)
            .blur(radius: amount * 3).opacity(1 - amount)
    }
}

struct CoverTurn: AnimatableModifier {
    var angle: Double
    var offset: CGFloat
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(angle, Double(offset)) }
        set { angle = newValue.first; offset = CGFloat(newValue.second) }
    }
    func body(content: Content) -> some View {
        let progress = min(1, abs(angle) / 32)
        content.rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .offset(x: offset).scaleEffect(1 - progress * 0.065).opacity(1 - progress)
    }
}

struct AnimatedCover: View {
    @ObservedObject var spotify: SpotifyController
    var compact = false
    @State private var nudged = false
    @State private var resetTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            CoverArt(artwork: spotify.artwork)
                .id(spotify.artworkRevision)
                .transition(reduceMotion ? .opacity : compact ? .modifier(active: CoverDissolve(amount: 1), identity: CoverDissolve(amount: 0)) : .asymmetric(
                    insertion: .modifier(active: CoverTurn(angle: Double(spotify.skipDirection) * 32, offset: CGFloat(spotify.skipDirection) * 4), identity: CoverTurn(angle: 0, offset: 0)),
                    removal: .modifier(active: CoverTurn(angle: Double(spotify.skipDirection) * -32, offset: CGFloat(spotify.skipDirection) * -4), identity: CoverTurn(angle: 0, offset: 0))))
        }
        .offset(x: !reduceMotion && nudged && !compact ? CGFloat(spotify.skipDirection) * -2 : 0)
        .scaleEffect(!reduceMotion && nudged ? (compact ? 0.92 : 0.97) : 1)
        .rotationEffect(.degrees(!reduceMotion && nudged && !compact ? Double(spotify.skipDirection) * -1.5 : 0))
        .animation(reduceMotion ? nil : IslandMotion.cover, value: nudged)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : IslandMotion.cover, value: spotify.artworkRevision)
        .onChange(of: spotify.skipPulse) { _ in
            resetTask?.cancel()
            nudged = true
            resetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                nudged = false
            }
        }
        .onDisappear { resetTask?.cancel() }
    }
}

struct CoverArt: View {
    let artwork: NSImage?
    var body: some View {
        Group {
            if let artwork { Image(nsImage: artwork).resizable().scaledToFill() }
            else {
                ZStack {
                    Color(white: 0.16)
                    Image(systemName: "music.note").foregroundStyle(.gray)
                }
            }
        }.accessibilityLabel("Album artwork")
    }
}

// Caption survives the closing animation; the shell clips it as it retracts.
struct TrackNoticeCaption: View {
    let text: String?
    let width: CGFloat
    @ObservedObject var library: SpotifyLibrary
    @State private var lastText = ""
    var body: some View {
        MarqueeLabel(text: text ?? lastText, size: 14, weight: .bold, explicit: library.explicitTrack == true, startDelay: 0.9, centerWhenFits: true, badgeScale: 1.18)
            .foregroundStyle(Color(white: 0.48))
            .frame(width: max(1, width - 32), height: 22)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
            .onAppear { if let text { lastText = text } }
            .onChange(of: text) { value in if let value { lastText = value } }
            .accessibilityHidden(text == nil)
    }
}

// One clipped line with a gentle continuous loop, never a moving layout box.
struct MarqueeLabel: View {
    let text: String
    var size: CGFloat = 14
    var weight: NSFont.Weight = .semibold
    var explicit = false
    var startDelay: TimeInterval = 1.2
    var centerWhenFits = false
    var badgeScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var epoch = Date()
    private var nativeFont: NSFont { .systemFont(ofSize: size, weight: weight) }
    private var lineWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: nativeFont]).width) + (explicit ? 6 + 10 * badgeScale : 0)
    }
    private var line: some View {
        HStack(spacing: 5) {
            Text(text).font(Font(nativeFont)).fixedSize()
            if explicit {
                Text("E").font(.system(size: 8 * badgeScale, weight: .heavy))
                    .foregroundStyle(.black).frame(width: 10 * badgeScale, height: 11 * badgeScale)
                    .background(Color(white: 0.88), in: RoundedRectangle(cornerRadius: 2))
            }
        }.frame(width: lineWidth, alignment: .leading)
    }
    var body: some View {
        GeometryReader { geometry in
            let overflows = lineWidth > geometry.size.width + 1
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !overflows || reduceMotion)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(epoch) - startDelay)
                let distance = lineWidth + 28
                let phase = elapsed.truncatingRemainder(dividingBy: Double(distance / 24) + 1.2)
                let offset = overflows && !reduceMotion ? min(CGFloat(phase) * 24, distance) : 0
                HStack(spacing: 28) { line; if overflows && !reduceMotion { line } }
                    .offset(x: -offset + (centerWhenFits && !overflows ? max(0, (geometry.size.width - lineWidth) / 2) : 0))
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                    .clipped()
                    .mask {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [offset > 0 ? .clear : .white, .white], startPoint: .leading, endPoint: .trailing).frame(width: 5)
                            Color.white
                            LinearGradient(colors: [.white, overflows ? .clear : .white], startPoint: .leading, endPoint: .trailing).frame(width: 7)
                        }
                    }
            }
        }
        .onChange(of: text) { _ in epoch = Date() }
        .onChange(of: explicit) { _ in epoch = Date() }
        .onAppear { epoch = Date() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text + (explicit ? ", Explicit" : ""))
        .help(text)
    }
}

struct TrackHeading: View {
    let title: String
    let artist: String
    @ObservedObject var library: SpotifyLibrary
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            MarqueeLabel(text: title, weight: .bold, explicit: library.explicitTrack == true)
                .foregroundStyle(.white).frame(height: 19)
            MarqueeLabel(text: artist).foregroundStyle(Color(white: 0.48)).frame(height: 19)
        }
    }
}

struct PlayerView: View {
    @ObservedObject private var modules = IslandModules.shared
    @ObservedObject var spotify: SpotifyController
    @ObservedObject var audio: AudioCapture
    let openLibrarySettings: () -> Void
    var queueAction: (() -> Void)? = nil
    var queueActive = false
    var toolsAction: (() -> Void)? = nil
    var artworkAction: (() -> Void)? = nil
    var locked = false
    var hideArtwork = false
    @AppStorage("artworkAccent") private var artworkAccent = false
        @State private var seeking = false
    @State private var seekPosition: Double = 0
    @State private var progressHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let scale = (geometry.size.width - 38) / 360
            ZStack(alignment: .topLeading) {
                if let toolsAction, modules.hasTools {
                    Button(action: toolsAction) { Text("Tools").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(white: 0.65)).frame(width: 42, height: 24) }.buttonStyle(SpringControlStyle()).accessibilityLabel("Activities, files and audio outputs").offset(x: 256, y: 4)
                }
                if !hideArtwork {
                AnimatedCover(spotify: spotify)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .offset(x: 20, y: 14)
                    .onTapGesture { artworkAction?() }
                }
                VStack(alignment: .leading, spacing: 1) {
                    if spotify.connected {
                        TrackHeading(title: spotify.title, artist: spotify.artist, library: spotify.library)
                    } else {
                        Button("Connect \(spotify.playerSource)") { spotify.openSpotify(); spotify.connect() }
                            .font(.system(size: 14, weight: .bold)).buttonStyle(.plain)
                        Text("Choose a song to begin").font(.system(size: 11)).foregroundStyle(.gray)
                    }
                }.frame(width: hideArtwork ? 269 : 197, height: 40, alignment: .center).offset(x: hideArtwork ? 24 : 96, y: 34)
                Button {
                    if !audio.running { Task { await audio.start() } }
                } label: {
                    Waveform(levels: audio.levels, tint: audio.running ? Color(nsColor: spotify.waveformTint) : .orange)
                        .frame(width: 18, height: 18).frame(width: 30, height: 30)
                }
                .buttonStyle(SpringControlStyle()).disabled(audio.busy || locked)
                .help(audio.running ? "Live selected-player audio" : "Enable reactive waveform")
                .accessibilityLabel(audio.running ? "Live selected-player audio waveform" : "Enable reactive waveform")
                .offset(x: 303, y: 34)
                progress.frame(width: 312, height: 20).offset(x: 24, y: 93)
                SpotifyHeart(library: spotify.library, playbackConnected: spotify.connected, openSettings: openLibrarySettings)
                    .position(x: queueAction == nil ? 77 : 46, y: 148)
                    .disabled(spotify.playerSource != "Spotify" || (locked && (!spotify.library.connected || spotify.library.error != nil)))
                if let queueAction, spotify.playerSource == "Spotify" {
                    Button(action: queueAction) { Image(systemName: "list.bullet").font(.system(size: 17, weight: .semibold)).frame(width: 30, height: 36) }
                        .buttonStyle(SpringControlStyle()).foregroundStyle(queueActive ? .white : Color(white: 0.48))
                        .accessibilityLabel(queueActive ? "Close song queue" : "Open song queue").position(x: 84, y: 148)
                }
                control("backward.fill", label: "Previous track", size: 22) { spotify.command(.previous) }
                    .position(x: 126, y: 148).disabled(!spotify.supportsSkipping)
                control(spotify.playing ? "pause.fill" : "play.fill", label: spotify.playing ? "Pause" : "Play", size: 27) { spotify.command(.toggle) }
                    .position(x: 180, y: 148)
                control("forward.fill", label: "Next track", size: 22) { spotify.command(.next) }
                    .position(x: 234, y: 148).disabled(!spotify.supportsSkipping)
                control("shuffle", label: "Toggle shuffle", size: 20, muted: !spotify.shuffling) { spotify.toggleShuffle() }
                    .position(x: 283, y: 148).disabled(spotify.browserSource)
            }
            .frame(width: 360, height: 189, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: 19)
        }
    }
    private var progress: some View {
        HStack(spacing: 8) {
            Text(time(seeking ? seekPosition : spotify.position)).frame(width: 38, alignment: .leading)
            GeometryReader { geometry in
                let duration = max(1, spotify.duration)
                let value = seeking ? seekPosition : spotify.position
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.14))
                    Rectangle().fill(artworkAccent ? Color(nsColor: spotify.waveformTint) : Color(white: seeking || progressHovered ? 0.94 : 0.65))
                        .frame(width: geometry.size.width * min(1, max(0, value / duration)))
                }
                .clipShape(Capsule()).frame(height: 8).frame(maxHeight: .infinity)
                .onHover { progressHovered = $0 }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard spotify.connected else { return }
                    seeking = true
                    seekPosition = min(1, max(0, event.location.x / geometry.size.width)) * duration
                }.onEnded { _ in
                    guard seeking else { return }
                    spotify.seek(seekPosition)
                    seeking = false
                })
                .accessibilityElement().accessibilityLabel("Track position")
                .accessibilityValue(time(value))
                .accessibilityAdjustableAction { direction in
                    spotify.seek(spotify.position + (direction == .increment ? 5 : -5))
                }
            }
            Text("-" + time(max(0, spotify.duration - (seeking ? seekPosition : spotify.position))))
                .frame(width: 39, alignment: .trailing)
        }.transaction { $0.animation = nil }
        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Color(white: 0.48))
    }
    private func control(_ symbol: String, label: String, size: CGFloat, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: size, weight: symbol == "shuffle" ? .medium : .bold)).frame(width: 30, height: 36) }
            .buttonStyle(SpringControlStyle()).foregroundStyle(muted ? Color(white: 0.24) : .white)
            .disabled(!spotify.connected).accessibilityLabel(label).help(label)
    }
    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value.isFinite ? value : 0))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct SpotifyHeart: View {
    @ObservedObject var library: SpotifyLibrary
    let playbackConnected: Bool
    let openSettings: () -> Void
    private var title: String {
        if !library.connected { return "Connect Spotify Liked Songs" }
        if library.saving { return "Updating Spotify…" }
        if library.currentURI == nil { return "This item cannot be saved to Liked Songs" }
        if library.liked == nil { return "Checking Spotify Liked Songs" }
        return library.liked == true ? "Remove from Spotify Liked Songs" : "Add to Spotify Liked Songs"
    }
    var body: some View {
        Button {
            if !library.connected || library.error != nil { openSettings() }
            else { Task { await library.toggleCurrent() } }
        } label: {
            ZStack {
                Image(systemName: library.liked == true ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .regular)).opacity(library.saving ? 0.3 : 1)
                if library.saving { ProgressView().controlSize(.mini) }
            }.frame(width: 30, height: 36)
        }
        .buttonStyle(SpringControlStyle())
        .foregroundStyle(library.liked == true ? Color(white: 0.5) : Color(white: 0.42))
        .disabled(library.saving || (library.connected && (!playbackConnected || library.currentURI == nil || (library.liked == nil && library.error == nil))))
        .help(title).accessibilityLabel(title)
        .animation(.easeInOut(duration: 0.18), value: library.liked)
    }
}

struct SpotifyLibrarySettings: View {
    @ObservedObject var library: SpotifyLibrary
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spotify Liked Songs").font(.headline)
            if library.connected {
                Text(library.status).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Refresh heart") { library.syncTrack(library.currentURI ?? "", force: true) }
                    Button("Disconnect") { library.disconnect() }
                }
            } else {
                TextField("Spotify Client ID", text: $library.clientID).textFieldStyle(.roundedBorder)
                    .disabled(library.signingIn)
                Text("In your Spotify Developer app, add this redirect URI:")
                    .font(.caption).foregroundStyle(.secondary)
                Text(SpotifyOAuth.redirect).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Copy redirect") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(SpotifyOAuth.redirect, forType: .string) }
                    Link("Developer dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                }.font(.caption)
                Text("Sign in with the same account as the Spotify desktop app. Only a Client ID is needed—never a client secret.")
                    .font(.caption).foregroundStyle(.secondary)
                if library.signingIn {
                    HStack { ProgressView().controlSize(.small); Text("Finish in your browser…").font(.caption); Button("Cancel") { library.cancelSignIn() } }
                } else {
                    Button("Connect Liked Songs") { library.signIn() }
                }
            }
            if let error = library.error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct Waveform: View {
    let levels: [Float]
    let tint: Color
    var maximumBarWidth: CGFloat = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var displayLevels: [Float] {
        guard levels.count == 5 else { return levels }
        return [max(levels[0], levels[1]), levels[2], levels[3], levels[4]]
    }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(displayLevels.indices, id: \.self) { index in
                    Capsule().fill(tint.opacity(0.5 + Double(displayLevels[index]) * 0.5))
                        .frame(width: min(maximumBarWidth, max(1, (geometry.size.width - CGFloat(displayLevels.count - 1) * 2) / CGFloat(max(1, displayLevels.count)))),
                               height: max(2, CGFloat(displayLevels[index]) * geometry.size.height))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.095), value: levels)
        }
    }
}

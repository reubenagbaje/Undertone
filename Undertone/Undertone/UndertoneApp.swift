import SwiftUI
import AppKit

enum IslandMotion {
    static let swipeReturn = Animation.interactiveSpring(response: 0.34, dampingFraction: 0.8, blendDuration: 0.12)
    static let finger = Animation.interactiveSpring(response: 0.12, dampingFraction: 0.86, blendDuration: 0.08)
    static let morph = Animation.interactiveSpring(response: 0.4, dampingFraction: 0.86, blendDuration: 0.16)
    static let retract = Animation.interactiveSpring(response: 0.32, dampingFraction: 0.92, blendDuration: 0.14)
    static let preview = Animation.interactiveSpring(response: 0.36, dampingFraction: 0.88, blendDuration: 0.14)
    static let hover = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.86, blendDuration: 0.14)
    static let cover = Animation.interactiveSpring(response: 0.36, dampingFraction: 0.84, blendDuration: 0.14)
}

@main struct UndertoneApp: App {
    @NSApplicationDelegateAdaptor(IslandDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandMenu("Player") {
                    Button("Show Player") { delegate.showPlayer() }.keyboardShortcut("o")
                    Button("Collapse Player") { delegate.collapsePlayer() }
                    Button("Player Settings…") { delegate.showSettings() }.keyboardShortcut(",")
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
    var dormant: Bool { !playbackActive && !previewing && !expanded && trackNotice == nil }
    var wingWidth: CGFloat { trackNotice != nil ? 44 : (previewing || swipeEngaged) ? 46 : 34 }
    var swipeVisual: SwipePresentation { SwipePresentation(progress: Double(swipeProgress), reversed: reverseSwipes) }
    var swipeExtension: CGFloat { expanded ? 0 : CGFloat(swipeVisual.extensionWidth) }
    var shellOffset: CGFloat { CGFloat(swipeVisual.forward ? 1 : -1) * swipeExtension / 2 }
    var shoulder: CGFloat { expanded ? 19 : CGFloat(idleCornerCurve) }
    var compactWidth: CGFloat { notchWidth + wingWidth * 2 + shoulder * 2 }
    var compactHeight: CGFloat { notchHeight + (previewing || swipeEngaged || trackNotice != nil ? 2 : 1) }
    var visibleWidth: CGFloat { expanded ? expandedWidth : dormant ? notchWidth : compactWidth + swipeExtension }
    var visibleHeight: CGFloat { expanded ? expandedHeight + notchHeight : dormant ? notchHeight : compactHeight + (trackNotice == nil ? 0 : 36) }
    func open() {
        guard !expanded else { return }
        if haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : IslandMotion.morph) { expanded = true }
    }
    func close() {
        pinned = false
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : IslandMotion.retract) { expanded = false }
    }
}

@MainActor final class IslandDelegate: NSObject, NSApplicationDelegate {
    private let spotify = SpotifyController()
    private let audio = AudioCapture()
    private let state = IslandState()
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
    private var lastTrackRevision = 0
    private var notice = TrackNoticeIntent()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
        Task { await audio.resumeIfEnabled() }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event)
        }
    }

    func showPlayer() { state.pinned = true; state.open() }
    func collapsePlayer() { state.close() }
    func showSettings() { state.open(); state.settingsOpen = true }

    private func position() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first,
              let panel else { return }
        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.notchWidth = max(1, right.minX - left.maxX)
            state.notchHeight = inset
            anchor = CGPoint(x: (left.maxX + right.minX) / 2, y: screen.frame.maxY)
        } else {
            state.notchWidth = 180
            state.notchHeight = 30
            anchor = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
        }
        state.expandedWidth = max(398, state.notchWidth + 208)
        state.expandedHeight = (state.expandedWidth - 38) / 360 * 189 - state.notchHeight
        let size = CGSize(width: state.expandedWidth + 40, height: state.expandedHeight + state.notchHeight + 48)
        panel.setFrame(NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height, width: size.width, height: size.height), display: true)
    }

    private func updatePointer() {
        guard let panel else { return }
        state.playbackActive = spotify.connected && spotify.playing
        let now = ProcessInfo.processInfo.systemUptime
        if spotify.trackRevision != lastTrackRevision {
            lastTrackRevision = spotify.trackRevision
            if state.playbackActive && !state.expanded {
                notice.show("\(spotify.artist) • \(spotify.title)", now: now)
            }
        }
        notice.update(now: now, dismiss: state.expanded || !spotify.connected)
        if state.trackNotice != notice.text { state.trackNotice = notice.text }
        let width = state.visibleWidth
        let height = state.visibleHeight + (state.dormant ? 3 : 0)
        let rect = NSRect(x: anchor.x + state.shellOffset - width / 2, y: anchor.y - height, width: width, height: height)
        let pointer = NSEvent.mouseLocation
        let inside = NotchHitTarget.contains(pointer, in: rect)
        // The tiny idle activation strip is pointer-tracked but remains click-through.
        panel.ignoresMouseEvents = (!inside && !swipeIntent.active) || state.dormant
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
        let canExpand = state.expanded || NotchHitTarget.contains(pointer, in: cameraTarget)
        let shouldOpen = hoverIntent.update(inside: inside && canExpand && !suppressHoverUntilExit, now: now)
        _ = peekIntent.update(inside: inside && !suppressHoverUntilExit, now: now)
        state.previewing = peekIntent.previewing || (inside && suppressHoverUntilExit)
        if inside {
            leaveTime = nil
            if shouldOpen { state.open() }
        } else if state.expanded, !state.pinned, !state.settingsOpen, NSEvent.pressedMouseButtons == 0 {
            if leaveTime == nil { leaveTime = Date() }
            if let leaveTime, Date().timeIntervalSince(leaveTime) > 0.45 {
                state.close()
                self.leaveTime = nil
            }
        }
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, !state.settingsOpen, event.hasPreciseScrollingDeltas else { return event }
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
        swipeSettleTask?.cancel()
        timer?.invalidate()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}

// Flush top edge and rounded lower corners merge the black wings into the camera housing.
struct IslandShape: Shape {
    var shoulder: CGFloat = 0
    var bottomRadius: CGFloat = 52
    var openTop = false
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottomRadius) }
        set { shoulder = newValue.first; bottomRadius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
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
                if state.expanded {
                    PlayerView(spotify: spotify, audio: audio, openLibrarySettings: { state.settingsOpen = true })
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
                            .popover(isPresented: $state.settingsOpen, arrowEdge: .bottom) {
                                IslandSettings(state: state, spotify: spotify, audio: audio)
                            }
                        }
                        .contextMenu { Button("Settings…") { state.settingsOpen = true } }
                        .transition(.opacity)
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
            .background { IslandSurface(glass: state.glassAppearance && state.expanded, shoulder: state.shoulder) }
            .clipShape(IslandShape(shoulder: state.shoulder, bottomRadius: state.expanded ? 46 : state.trackNotice == nil ? 10 : 20))
            .overlay {
                if state.whiteOutline {
                    IslandShape(shoulder: state.shoulder, bottomRadius: state.expanded ? 46 : state.trackNotice == nil ? 10 : 20, openTop: true).stroke(.white.opacity(0.65), lineWidth: 0.75)
                        .padding(0.375).allowsHitTesting(false)
                }
            }
            .offset(x: state.shellOffset)
            .opacity(state.dormant ? 0 : 1)
            .shadow(color: .black.opacity(state.expanded ? 0.32 : 0.22), radius: state.expanded ? 14 : 5, y: state.expanded ? 7 : 3)
            .animation(reduceMotion ? nil : state.swipeTracking ? IslandMotion.finger : IslandMotion.swipeReturn, value: state.swipeProgress)
            .animation(reduceMotion ? nil : IslandMotion.hover, value: state.swipeEngaged)
            .animation(reduceMotion ? nil : state.expanded ? IslandMotion.morph : IslandMotion.retract, value: state.expanded)
            .animation(reduceMotion ? nil : IslandMotion.hover, value: state.previewing)
            .animation(reduceMotion ? nil : IslandMotion.hover, value: state.idleCornerCurve)
            .animation(reduceMotion ? nil : IslandMotion.preview, value: state.glassAppearance)
            .animation(reduceMotion ? nil : IslandMotion.morph, value: state.playbackActive)
            .animation(reduceMotion ? nil : state.trackNotice == nil ? IslandMotion.retract : IslandMotion.preview, value: state.trackNotice)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark).ignoresSafeArea()
    }
}

// Glass is behind the controls, with an opaque camera region and a smooth
// fade ending halfway down. Older systems use native translucent material.
struct IslandSurface: View {
    let glass: Bool
    let shoulder: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if glass && !reduceTransparency {
            ZStack {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.regular, in: IslandShape(shoulder: shoulder, bottomRadius: 46))
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
                .foregroundStyle(.white).frame(height: 17)
            MarqueeLabel(text: artist).foregroundStyle(Color(white: 0.48)).frame(height: 17)
        }
    }
}

struct PlayerView: View {
    @ObservedObject var spotify: SpotifyController
    @ObservedObject var audio: AudioCapture
    let openLibrarySettings: () -> Void
    @State private var seeking = false
    @State private var seekPosition: Double = 0
    @State private var progressHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let scale = (geometry.size.width - 38) / 360
            ZStack(alignment: .topLeading) {
                AnimatedCover(spotify: spotify)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .offset(x: 20, y: 14)
                VStack(alignment: .leading, spacing: 1) {
                    if spotify.connected {
                        TrackHeading(title: spotify.title, artist: spotify.artist, library: spotify.library)
                    } else {
                        Button("Connect Spotify") { spotify.openSpotify(); spotify.connect() }
                            .font(.system(size: 14, weight: .bold)).buttonStyle(.plain)
                        Text("Choose a song to begin").font(.system(size: 11)).foregroundStyle(.gray)
                    }
                }.frame(width: 197, height: 34, alignment: .bottomLeading).offset(x: 96, y: 38)
                Button {
                    if !audio.running { Task { await audio.start() } }
                } label: {
                    Waveform(levels: audio.levels, tint: audio.running ? Color(nsColor: spotify.waveformTint) : .orange)
                        .frame(width: 18, height: 18).frame(width: 30, height: 30)
                }
                .buttonStyle(SpringControlStyle()).disabled(audio.busy)
                .help(audio.running ? "Live Spotify audio" : "Enable reactive waveform")
                .accessibilityLabel(audio.running ? "Live Spotify audio waveform" : "Enable reactive waveform")
                .offset(x: 303, y: 34)
                progress.frame(width: 312, height: 20).offset(x: 24, y: 93)
                SpotifyHeart(library: spotify.library, playbackConnected: spotify.connected, openSettings: openLibrarySettings)
                    .position(x: 77, y: 148)
                control("backward.fill", label: "Previous track", size: 19) { spotify.command(.previous) }
                    .position(x: 126, y: 148)
                control(spotify.playing ? "pause.fill" : "play.fill", label: spotify.playing ? "Pause" : "Play", size: 23) { spotify.command(.toggle) }
                    .position(x: 180, y: 148)
                control("forward.fill", label: "Next track", size: 19) { spotify.command(.next) }
                    .position(x: 234, y: 148)
                control("shuffle", label: "Toggle shuffle", size: 18, muted: !spotify.shuffling) { spotify.toggleShuffle() }
                    .position(x: 283, y: 148)
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
                    Rectangle().fill(Color(white: seeking || progressHovered ? 0.94 : 0.65))
                        .frame(width: geometry.size.width * min(1, max(0, value / duration)))
                }
                .clipShape(Capsule()).frame(height: 7).frame(maxHeight: .infinity)
                .onHover { progressHovered = $0 }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard spotify.connected else { return }
                    seeking = true
                    seekPosition = min(1, max(0, event.location.x / geometry.size.width)) * duration
                }.onEnded { _ in
                    guard seeking else { return }
                    seeking = false
                    spotify.seek(seekPosition)
                })
                .accessibilityElement().accessibilityLabel("Track position")
                .accessibilityValue(time(value))
                .accessibilityAdjustableAction { direction in
                    spotify.seek(spotify.position + (direction == .increment ? 5 : -5))
                }
            }
            Text("-" + time(max(0, spotify.duration - (seeking ? seekPosition : spotify.position))))
                .frame(width: 39, alignment: .trailing)
        }.font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Color(white: 0.48))
    }
    private func control(_ symbol: String, label: String, size: CGFloat, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: size, weight: symbol == "shuffle" ? .regular : .semibold)).frame(width: 30, height: 36) }
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

struct IslandSettings: View {
    @ObservedObject var state: IslandState
    @ObservedObject var spotify: SpotifyController
    @ObservedObject var audio: AudioCapture
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Undertone").font(.headline)
            Toggle("Hover haptics", isOn: $state.haptics)
            Toggle("Keep player expanded", isOn: $state.pinned)
            Toggle("Thin white outline", isOn: $state.whiteOutline)
            Toggle("Black to Liquid Glass", isOn: $state.glassAppearance)
            Text("Expanded player fades from black around the camera to glass below.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Idle top-corner curve")
                Slider(value: $state.idleCornerCurve, in: 0...16, step: 1)
                    .accessibilityLabel("Idle top-corner curve")
                    .accessibilityValue("\(Int(state.idleCornerCurve)) of 16")
                HStack {
                    Text("Straight")
                    Spacer()
                    Text("More curved")
                }.font(.caption).foregroundStyle(.secondary)
                Text("Adjusts how the compact notch curves into the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset curve") { state.idleCornerCurve = 6 }
                    .font(.caption)
            }
            Toggle("Reverse swipe direction", isOn: $state.reverseSwipes)
            Text("Hover to gently enlarge, then keep hovering to open. When paused, hover just beneath the camera to reveal the player. Move away after swiping to enable hover again.")
            Text(state.reverseSwipes ? "Swipe right for next; left to restart or go back." : "Swipe left for next; right to restart or go back.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Open Spotify") { spotify.openSpotify() }
                Button("Reconnect") { spotify.connect() }
            }
            Button(audio.busy ? "Please wait…" : audio.running ? "Stop Spotify audio" : "Enable Spotify audio") {
                Task { if audio.running { await audio.stop() } else { await audio.start() } }
            }.disabled(audio.busy)
            Text(audio.message).font(.caption).foregroundStyle(.secondary)
            if audio.running {
                Text("Audio frames received: \(audio.receivedFrames) • Peak: \(Int(audio.peakLevel * 100))%").font(.caption2).monospacedDigit()
                Button("Restart audio") { Task { await audio.restart() } }.disabled(audio.busy)
            }
            if let error = spotify.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Divider()
            SpotifyLibrarySettings(library: spotify.library)
            HStack {
                Button("Privacy settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!) }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }.padding(20).frame(width: 340).toggleStyle(.checkbox)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text("Made by Reuben Agbaje")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.regularMaterial)
        }
        .frame(width: 340, height: 540).preferredColorScheme(.dark)
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

import SwiftUI
import AppKit
import CoreAudio
import ServiceManagement
import Carbon
import Sparkle

@MainActor final class DeviceControls: ObservableObject {
    @Published var volume: Double = 0
    @Published var brightness: Double = 0
    @Published var volumeAvailable = false
    @Published var brightnessAvailable = false
    @Published var displayName = "Display"
    @Published var message: String?
    private var device = AudioDeviceID(0)
    private var volumeElements: [AudioObjectPropertyElement] = []
    private var display = CGDirectDisplayID(0)
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
    private var getBrightness: GetBrightness? {
        guard let displayServices, let symbol = dlsym(displayServices, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }
    private var setBrightness: SetBrightness? {
        guard let displayServices, let symbol = dlsym(displayServices, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: SetBrightness.self)
    }
    func refresh() {
        message = nil
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
        volumeAvailable = false; volumeElements = []
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &device) == noErr {
            for element: AudioObjectPropertyElement in [0, 1, 2] {
                address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                var writable = DarwinBoolean(false)
                guard AudioObjectHasProperty(device, &address), AudioObjectIsPropertySettable(device, &address, &writable) == noErr, writable.boolValue else { continue }
                var value: Float32 = 0; bytes = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &value) == noErr {
                    if volumeElements.isEmpty { volume = Double(value) }
                    volumeElements.append(element)
                    if element == 0 { break }
                }
            }
            volumeAvailable = !volumeElements.isEmpty
            var muted: UInt32 = 0
            address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            bytes = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &muted) == noErr, muted != 0 { volume = 0 }
        }
        // Prefer the screen under the pointer, including a supported external display.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        display = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        displayName = screen?.localizedName ?? "Display"
        var value: Float = 0
        brightnessAvailable = getBrightness?(display, &value) == 0 && setBrightness != nil
        if brightnessAvailable { brightness = Double(value) }
    }
    func changeVolume(_ value: Double) {
        guard volumeAvailable, value.isFinite else { return }
        var current = AudioDeviceID(0)
        var output = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &output, 0, nil, &bytes, &current) == noErr else { return }
        if current != device { refresh() }
        guard volumeAvailable else { return }
        volume = min(1, max(0, value))
        var scalar = Float32(volume)
        for element in volumeElements {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) != noErr {
                refresh(); message = "The output device could not change volume."; return
            }
        }
    }
    func changeBrightness(_ value: Double) {
        guard brightnessAvailable, value.isFinite else { return }
        brightness = min(1, max(0.05, value))
        if setBrightness?(display, Float(brightness)) != 0 { message = "This display could not change brightness."; brightnessAvailable = false }
    }
}

@MainActor final class SleepTimer: ObservableObject {
    @Published private(set) var deadline: Date?
    private var timer: Timer?
    private var schedule = SleepSchedule()
    func start(minutes: Int, pause: @escaping () -> Void) {
        cancel()
        guard minutes > 0 else { return }
        schedule.start(minutes: minutes)
        deadline = schedule.deadline
        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.schedule.consumeExpiration() else { return }
                self.cancel(); pause()
            }
        }
        timer = tick; RunLoop.main.add(tick, forMode: .common)
    }
    func cancel() { timer?.invalidate(); timer = nil; schedule.cancel(); deadline = nil }
}

@MainActor final class LoginLaunch: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    @Published var message: String?
    func set(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            enabled = SMAppService.mainApp.status == .enabled
            message = SMAppService.mainApp.status == .requiresApproval ? "Allow Undertone in System Settings → General → Login Items." : nil
        } catch { message = error.localizedDescription; enabled = SMAppService.mainApp.status == .enabled }
    }
}

// Carbon registers discrete shortcuts without recording general keyboard input.
@MainActor final class PlayerShortcuts {
    private var handler: EventHandlerRef?
    private var keys: [EventHotKeyRef] = []
    var action: ((UInt32) -> Void)?
    func start() {
        stop()
        guard UserDefaults.standard.object(forKey: "enablePlayerShortcuts") as? Bool ?? true else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let owner = Unmanaged<PlayerShortcuts>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.action?(id.id) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        for (id, key) in [(1, kVK_ANSI_U), (2, kVK_Space), (3, kVK_RightArrow), (4, kVK_LeftArrow), (5, kVK_ANSI_L), (6, kVK_ANSI_K)] {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey), EventHotKeyID(signature: 0x554E4452, id: UInt32(id)), GetApplicationEventTarget(), 0, &ref) == noErr, let ref { keys.append(ref) }
        }
    }
    func stop() {
        keys.forEach { UnregisterEventHotKey($0) }; keys.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}

struct NotchLevelView: View {
    let kind: String
    let value: Double
    var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind == "Brightness" ? "sun.max.fill" : value < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 17, weight: .semibold)).frame(width: 24)
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.16)).overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: g.size.width * min(1, max(0, value)))
                }
            }.frame(height: 9)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 40)
        }.padding(.horizontal, expanded ? 54 : 32).padding(.bottom, expanded ? 18 : 10).foregroundStyle(.white)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: value)
        .accessibilityElement(children: .ignore).accessibilityLabel(kind).accessibilityValue("\(Int(value * 100)) percent")
    }
}

struct NotchQueueView: View {
    @ObservedObject var spotify: SpotifyController
    @ObservedObject var library: SpotifyLibrary
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(.white.opacity(0.08))
            HStack {
                Text("Up Next").font(.system(size: 16, weight: .bold))
                Spacer()
                if library.queueLoading { ProgressView().controlSize(.small) }
                Button { Task { await library.loadQueue() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(SpringControlStyle()).disabled(library.queueLoading).accessibilityLabel("Refresh queue")
            }
            if let error = library.queueError { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if !library.connected || library.queueError != nil {
                Button("Connect Spotify queue…") { library.signIn() }.disabled(library.signingIn)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(library.queue.enumerated()), id: \.offset) { index, track in
                        Button { spotify.playURI(track.uri) } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(track.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                            }.padding(.vertical, 8).padding(.horizontal, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(SpotifyOAuth.trackURI(track.uri) == nil || !spotify.connected)
                    }
                    if library.queue.isEmpty && !library.queueLoading && library.queueError == nil {
                        Text("Your upcoming songs will appear here.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }
            }
            Text("Play a song now · Spotify may update the remaining queue")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(.horizontal, 32).padding(.bottom, 24).foregroundStyle(.white)
        .task { await library.loadQueue() }
        .onChange(of: spotify.trackRevision) { _ in Task { await library.loadQueue() } }
    }
}

struct SleepTimerSettings: View {
    @ObservedObject var timer: SleepTimer
    let pause: () -> Void
    var body: some View {
        Menu(timer.deadline == nil ? "Set sleep timer" : "Change sleep timer") {
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(minutes) minutes") { timer.start(minutes: minutes, pause: pause) }
            }
            Button("Cancel timer") { timer.cancel() }
        }
        if let deadline = timer.deadline { Text("Pauses at \(deadline.formatted(date: .omitted, time: .shortened))").font(.caption) }
    }
}

@MainActor final class AppUpdates: ObservableObject {
    static let shared = AppUpdates()
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    var automatic: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
    var installAutomatically: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }
    func check() { controller.checkForUpdates(nil) }
}

struct UpdateSettings: View {
    @ObservedObject private var updates = AppUpdates.shared
    var body: some View {
        Toggle("Automatically check for updates", isOn: Binding(get: { updates.automatic }, set: { updates.automatic = $0 }))
        Toggle("Download and install updates automatically", isOn: Binding(get: { updates.installAutomatically }, set: { updates.installAutomatically = $0 })).disabled(!updates.automatic)
        Button("Check for Updates…") { updates.check() }
        Text("Updates are verified before installation. Updates are delivered from the official Undertone GitHub releases.").font(.caption).foregroundStyle(.secondary)
    }
}

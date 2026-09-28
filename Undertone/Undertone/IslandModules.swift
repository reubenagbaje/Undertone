import SwiftUI
import AppKit
import CoreAudio
import IOKit.ps
import IOBluetooth
import UniformTypeIdentifiers

struct OutputRoute: Identifiable { let id: AudioDeviceID; let name: String }
@MainActor final class IslandModules: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = IslandModules()
    @Published var routes: [OutputRoute] = []
    @Published var output: AudioDeviceID = 0
    @Published var message: String?
    @Published var activity: String?
    @Published var activitySymbol = "timer"
    @Published var files: [URL] = []
    @Published private(set) var countdown = ActivityCountdown()
    @Published private(set) var timerNow = Date()
    @Published var selectedTab = 0
    var remaining: Int { countdown.remaining(at: timerNow) }
    var timerActive: Bool { timersEnabled && countdown.active }
    var timerText: String { ActivityCountdown.formatted(remaining) }
    @Published var downloadProgress: Double?
    @Published var downloading = false
    @Published var downloadName = ""
    @Published var batteryText = ""
    @Published var headphones: [String] = []
    @Published var presentation = false { didSet { NotificationCenter.default.post(name: .init("UndertonePresentationChanged"), object: nil) } }
    @Published var timersEnabled = UserDefaults.standard.bool(forKey: "enableActivityTimers") { didSet { changed("enableActivityTimers", timersEnabled); if !timersEnabled { cancelTimer() } } }
    @Published var downloadsEnabled = UserDefaults.standard.bool(forKey: "enableActivityDownloads") { didSet { changed("enableActivityDownloads", downloadsEnabled); if !downloadsEnabled { cancelDownload() } } }
    @Published var shelfEnabled = UserDefaults.standard.bool(forKey: "enableFileShelf") { didSet { changed("enableFileShelf", shelfEnabled); if !shelfEnabled { files = [] } } }
    @Published var outputsEnabled = UserDefaults.standard.bool(forKey: "enableOutputSwitcher") { didSet { changed("enableOutputSwitcher", outputsEnabled); if outputsEnabled { refreshRoutes() } else { routes = [] } } }
    @Published var batteryEnabled = UserDefaults.standard.bool(forKey: "batteryActivities") { didSet { changed("batteryActivities", batteryEnabled); if !batteryEnabled { batteryText = ""; previousCharging = nil; activity = nil } } }
    @Published var headphonesEnabled = UserDefaults.standard.bool(forKey: "headphoneActivities") { didSet { changed("headphoneActivities", headphonesEnabled); if !headphonesEnabled { headphones = []; previousDevices = nil; activity = nil } } }
    var hasTools: Bool { timersEnabled || downloadsEnabled || shelfEnabled || outputsEnabled || batteryEnabled || headphonesEnabled }
    private func changed(_ key: String, _ value: Bool) { UserDefaults.standard.set(value, forKey: key) }
    private var timer: Timer?
    private var ticks = 0
    private var noticeUntil = Date.distantPast
    private var previousCharging: Bool?
    private var previousDevices: Set<String>?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var session: URLSession?
    func start() {
        guard timer == nil else { return }
        if outputsEnabled { refreshRoutes() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func setSleeping(_ sleeping: Bool) { timer?.fireDate = sleeping ? .distantFuture : Date() }
    func stop() { timer?.invalidate(); timer = nil; task?.cancel(); session?.invalidateAndCancel() }
    func announce(_ text: String, symbol: String) { activity = text; activitySymbol = symbol; noticeUntil = Date().addingTimeInterval(5) }
    func startTimer(minutes: Int) {
        guard timersEnabled else { return }
        timerNow = Date(); countdown.start(seconds: Double(minutes * 60), now: timerNow)
        selectedTab = 0
    }
    func toggleTimer() { timerNow = Date(); countdown.togglePause(now: timerNow) }
    func restartTimer() { timerNow = Date(); countdown.start(seconds: countdown.duration, now: timerNow) }
    func cancelTimer() { countdown.cancel() }
    private func tick() {
        ticks += 1
        if countdown.deadline != nil { timerNow = Date() }
        if countdown.deadline != nil && countdown.consumeExpiration(now: timerNow) { NSSound(named: "Glass")?.play() }
        if ticks % 5 == 0 {
            if batteryEnabled { readBattery() }
            if headphonesEnabled { readHeadphones() }
        }
        if Date() > noticeUntil {
            if downloading { activity = downloadProgress.map { "Downloading · \(Int($0 * 100))%" } ?? "Downloading…"; activitySymbol = "arrow.down.circle" }
            else { activity = nil }
        }
    }
    private func readBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any], d["Type"] as? String == "InternalBattery" else { continue }
            let current = d["Current Capacity"] as? Int ?? 0, maxValue = max(1, d["Max Capacity"] as? Int ?? 100)
            let percent = Int(Double(current) / Double(maxValue) * 100)
            let charging = d["Is Charging"] as? Bool ?? false
            batteryText = "Battery \(percent)% · \(charging ? "Charging" : "Not charging")"
            if previousCharging != nil, previousCharging != charging { announce(batteryText, symbol: charging ? "battery.100.bolt" : "battery.100") }
            previousCharging = charging
        }
    }
    private func readHeadphones() {
        let connected = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() && ($0.name?.localizedCaseInsensitiveContains("AirPods") == true || $0.name?.localizedCaseInsensitiveContains("Beats") == true) }
        let names = connected.compactMap(\.name)
        let ids = Set(connected.compactMap(\.addressString))
        headphones = names.map { name in
            if let percent = peripheralBattery(named: name) { return "\(name) · \(percent)%" }
            return "\(name) · Battery unavailable"
        }
        if let previousDevices, let new = connected.first(where: { !previousDevices.contains($0.addressString ?? "") }), let name = new.name {
            let suffix = peripheralBattery(named: name).map { " · \($0)%" } ?? ""
            announce(name + " connected" + suffix, symbol: "airpodspro")
        }
        previousDevices = ids
    }
    private func peripheralBattery(named name: String) -> Int? {
        // Some Bluetooth peripherals publish battery data as power sources; never invent it.
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any], d["Name"] as? String == name,
                  let current = d["Current Capacity"] as? Int, let maximum = d["Max Capacity"] as? Int, maximum > 0 else { continue }
            return min(100, max(0, current * 100 / maximum))
        }
        return nil
    }
    func refreshRoutes() {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &devices) == noErr else { return }
        routes = devices.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
            var count: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &count) == noErr, count > 0 else { return nil }
            var name: Unmanaged<CFString>?
            var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &n, &name) == noErr, let name else { return nil }
            return OutputRoute(id: id, name: name.takeRetainedValue() as String)
        }
        a.mSelector = kAudioHardwarePropertyDefaultOutputDevice; size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &output)
    }
    func selectOutput(_ id: AudioDeviceID) {
        guard outputsEnabled else { return }
        var value = id
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        if AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) != noErr { message = "This output could not be selected." }
        else { message = nil }
        refreshRoutes()
    }
    func accept(_ providers: [NSItemProvider]) -> Bool {
        guard shelfEnabled else { return false }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    guard let self, self.shelfEnabled, !self.files.contains(url), self.files.count < 20 else { return }
                    self.files.append(url); self.announce("File added to shelf", symbol: "tray.and.arrow.down")
                }
            }
        }
        return true
    }
    func download(_ text: String) {
        guard downloadsEnabled else { return }
        guard !downloading, let url = ActivityDownloadURL.parse(text) else { message = "Enter an HTTPS download link."; return }
        let save = NSSavePanel(); save.nameFieldStringValue = url.lastPathComponent.isEmpty ? "Download" : url.lastPathComponent
        guard save.runModal() == .OK, let path = save.url else { return }
        destination = path; downloadName = path.lastPathComponent; message = nil; downloadProgress = nil; downloading = true
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session?.downloadTask(with: url); task?.resume()
    }
    func cancelDownload() { task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil; destination = nil; downloading = false; downloadProgress = nil; activity = nil }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in guard self.task === downloadTask else { return }; self.downloadProgress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Delegate queue is main; move the temporary download before returning.
        MainActor.assumeIsolated {
            guard task === downloadTask, let destination else { return }
            do {
                guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
                if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: location) }
                else { try FileManager.default.moveItem(at: location, to: destination) }
                if shelfEnabled, files.count < 20 { files.append(destination) }
                announce("Download complete · \(destination.lastPathComponent)", symbol: "checkmark.circle")
            } catch { message = error.localizedDescription }
            downloading = false; downloadProgress = nil
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            guard self.task === task else { return }
            if let error, (error as NSError).code != NSURLErrorCancelled { self.message = error.localizedDescription }
            self.downloading = false; self.task = nil; self.destination = nil
            session.finishTasksAndInvalidate(); self.session = nil
        }
    }
}

struct IslandToolsView: View {
    @ObservedObject private var modules = IslandModules.shared
    @State private var downloadURL = ""
    private var selected: Int { modules.selectedTab }
    private var availableTabs: [Int] {
        var tabs: [Int] = []
        if modules.timersEnabled || modules.downloadsEnabled || modules.batteryEnabled || modules.headphonesEnabled { tabs.append(0) }
        if modules.shelfEnabled { tabs.append(1) }
        if modules.outputsEnabled { tabs.append(2) }
        return tabs
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(availableTabs, id: \.self) { tab in
                    Button { modules.selectedTab = tab } label: {
                        Label(["Activities", "Files", "Sound"][tab], systemImage: ["timer", "tray", "speaker.wave.2"][tab])
                            .font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(.white.opacity(selected == tab ? 0.16 : 0.04), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.bottom, 8)
            if selected == 0 {
                if modules.timersEnabled {
                    if modules.timerActive { LiveTimerCard().frame(height: 86) }
                    else {
                        HStack {
                            Label("Timer", systemImage: "timer").foregroundStyle(.orange)
                            Spacer()
                            Menu("Start timer") { ForEach([1, 5, 10, 25, 45, 60], id: \.self) { n in Button("\(n) minutes") { modules.startTimer(minutes: n) } } }
                        }.padding(.vertical, 10)
                    }
                }
                if !modules.batteryText.isEmpty { Label(modules.batteryText, systemImage: "battery.100") }
                ForEach(modules.headphones, id: \.self) { Text($0).font(.caption) }
                if modules.downloadsEnabled {
                Divider().overlay(.white.opacity(0.1))
                TextField("HTTPS download link", text: $downloadURL).textFieldStyle(.plain).padding(10).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                HStack { Button("Download…") { modules.download(downloadURL) }.disabled(modules.downloading); if modules.downloading { Button("Cancel") { modules.cancelDownload() } } }
                if modules.downloading { ProgressView(value: modules.downloadProgress); Text(modules.downloadName).font(.caption).lineLimit(1) }
                Text("Tracks downloads started here. Files are saved where you choose.").font(.caption2).foregroundStyle(.secondary)
                }
            } else if selected == 1 {
                Text("Drop files onto the island, then drag them into another app.").font(.caption).foregroundStyle(.secondary)
                if modules.files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 25, weight: .light))
                        Text("Your shelf is empty").font(.system(size: 13, weight: .semibold))
                    }.foregroundStyle(.white.opacity(0.45)).frame(maxWidth: .infinity).padding(.vertical, 22)
                }
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(modules.files, id: \.self) { url in
                            HStack {
                                Label(url.lastPathComponent, systemImage: "doc").lineLimit(1).onDrag { NSItemProvider(object: url as NSURL) }
                                Spacer()
                                Button { modules.files.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle") }.help("Remove from shelf; keeps original file")
                            }.padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                Button("Clear shelf") { modules.files.removeAll() }.disabled(modules.files.isEmpty)
            } else {
                Picker("Audio output", selection: Binding(get: { modules.output }, set: modules.selectOutput)) { ForEach(modules.routes) { route in Text(route.name).tag(route.id) } }
                Button("Refresh outputs") { modules.refreshRoutes() }
                Text("Uses devices available in macOS Sound settings.").font(.caption).foregroundStyle(.secondary)
            }
            if let message = modules.message { Text(message).font(.caption).foregroundStyle(.orange).lineLimit(3) }
            Spacer(minLength: 0)
        }.font(.system(size: 12, weight: .medium)).buttonStyle(IslandToolButtonStyle()).tint(.white).controlSize(.small).padding(.horizontal, 32).padding(.bottom, 24).foregroundStyle(.white)
            .onAppear { if !availableTabs.contains(selected) { modules.selectedTab = availableTabs.first ?? 0 }; if modules.outputsEnabled { modules.refreshRoutes() } }
            .onChange(of: availableTabs) { tabs in if !tabs.contains(selected) { modules.selectedTab = tabs.first ?? 0 } }
    }
}

extension NSScreen {
    var undertoneID: String {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id.uint32Value)?.takeRetainedValue() else { return localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
struct ModulePreferences: View {
    @ObservedObject var state: IslandState
    @ObservedObject private var modules = IslandModules.shared
    @AppStorage("animationIntensity") private var intensity = 1.0
    var body: some View {
        Section("Optional tools") {
            Toggle("Timers", isOn: $modules.timersEnabled)
            Toggle("Downloads", isOn: $modules.downloadsEnabled)
            Toggle("Drag-and-drop file shelf", isOn: $modules.shelfEnabled)
            Toggle("Audio output switcher", isOn: $modules.outputsEnabled)
            Text("Off by default. Enable only the tools you want in the expanded player. Turning a tool off stops its active task; original files are kept.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Live Activities") {
            Toggle("Battery charging notifications", isOn: $modules.batteryEnabled)
            Toggle("AirPods and Beats connection notifications", isOn: $modules.headphonesEnabled)
            Text("Headphone battery appears when macOS provides it. Open Tools in the expanded player for timers, downloads, files and audio outputs.").font(.caption).foregroundStyle(.secondary)
            Toggle("Presentation mode — hide Undertone", isOn: $modules.presentation)
            Text("Restore from settings or ⌘⌥P. Presentation mode also hides the lock-screen player.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Display and motion") {
            Picker("Display", selection: $state.selectedDisplay) {
                Text("Automatic").tag("auto")
                ForEach(NSScreen.screens, id: \.undertoneID) { screen in Text(screen.localizedName).tag(screen.undertoneID) }
            }
            Picker("Size preset", selection: $state.appearancePreset) {
                ForEach(["Compact", "Comfortable", "Minimal"], id: \.self) { Text($0).tag($0) }
            }
            Text("Dynamic Island remembers its vertical gap for each selected display. A disconnected display falls back automatically.").font(.caption).foregroundStyle(.secondary)
            Slider(value: $intensity, in: 0...1.5).accessibilityLabel("Animation intensity")
            HStack { Text("Still"); Spacer(); Text("Animation intensity"); Spacer(); Text("Playful") }.font(.caption)
        }
    }
}

struct IslandToolButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.09), in: Capsule())
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct LiveTimerCard: View {
    @ObservedObject private var modules = IslandModules.shared
    var body: some View {
        HStack(spacing: 10) {
            Button { modules.countdown.finished ? modules.restartTimer() : modules.toggleTimer() } label: {
                Image(systemName: modules.countdown.finished ? "arrow.counterclockwise" : modules.countdown.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 19, weight: .semibold)).frame(width: 46, height: 46)
                    .foregroundStyle(.orange).background(.orange.opacity(0.19), in: Circle())
            }.accessibilityLabel(modules.countdown.finished ? "Restart timer" : modules.countdown.paused ? "Resume timer" : "Pause timer")
            Button { modules.cancelTimer() } label: {
                Image(systemName: "xmark").font(.system(size: 19, weight: .medium)).frame(width: 46, height: 46)
                    .foregroundStyle(.white).background(.white.opacity(0.15), in: Circle())
            }.accessibilityLabel("Cancel timer")
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text(modules.countdown.finished ? "Timer finished" : modules.countdown.paused ? "Paused" : "Timer")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange.opacity(0.85))
                Text(modules.timerText).font(.system(size: 32, weight: .regular))
                    .monospacedDigit().foregroundStyle(.orange).minimumScaleFactor(0.65).lineLimit(1)
            }
        }.buttonStyle(.plain).accessibilityElement(children: .contain)
    }
}

struct CompactTimerSymbol: View {
    @ObservedObject private var modules = IslandModules.shared
    var body: some View {
        ZStack {
            Circle().stroke(.orange.opacity(0.22), lineWidth: 2)
            Circle().trim(from: 0, to: modules.countdown.progress(at: modules.timerNow))
                .stroke(.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            Image(systemName: modules.countdown.finished ? "checkmark" : modules.countdown.paused ? "pause.fill" : "timer")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
        }.frame(width: 22, height: 22)
    }
}

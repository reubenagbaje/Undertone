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
    @Published var deadline: Date?
    @Published var remaining = 0
    @Published var downloadProgress: Double?
    @Published var downloading = false
    @Published var downloadName = ""
    @Published var batteryText = ""
    @Published var headphones: [String] = []
    @Published var presentation = false { didSet { NotificationCenter.default.post(name: .init("UndertonePresentationChanged"), object: nil) } }
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
        refreshRoutes()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func setSleeping(_ sleeping: Bool) { timer?.fireDate = sleeping ? .distantFuture : Date() }
    func stop() { timer?.invalidate(); timer = nil; task?.cancel(); session?.invalidateAndCancel() }
    func announce(_ text: String, symbol: String) { activity = text; activitySymbol = symbol; noticeUntil = Date().addingTimeInterval(5) }
    func startTimer(minutes: Int) { deadline = Date().addingTimeInterval(Double(minutes * 60)); tick() }
    func cancelTimer() { deadline = nil; remaining = 0; activity = nil }
    private func tick() {
        ticks += 1
        if let deadline {
            remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
            if remaining == 0 { self.deadline = nil; announce("Timer finished", symbol: "timer"); NSSound(named: "Glass")?.play() }
        }
        if ticks % 5 == 0 {
            if UserDefaults.standard.bool(forKey: "batteryActivities") { readBattery() }
            if UserDefaults.standard.bool(forKey: "headphoneActivities") { readHeadphones() }
        }
        if Date() > noticeUntil {
            if deadline != nil { activity = "Timer · \(remaining / 60):\(String(format: "%02d", remaining % 60))"; activitySymbol = "timer" }
            else if downloading { activity = downloadProgress.map { "Downloading · \(Int($0 * 100))%" } ?? "Downloading…"; activitySymbol = "arrow.down.circle" }
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
        var value = id
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        if AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) != noErr { message = "This output could not be selected." }
        else { message = nil }
        refreshRoutes()
    }
    func accept(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    guard let self, !self.files.contains(url), self.files.count < 20 else { return }
                    self.files.append(url); self.announce("File added to shelf", symbol: "tray.and.arrow.down")
                }
            }
        }
        return true
    }
    func download(_ text: String) {
        guard !downloading, let url = ActivityDownloadURL.parse(text) else { message = "Enter an HTTPS download link."; return }
        let save = NSSavePanel(); save.nameFieldStringValue = url.lastPathComponent.isEmpty ? "Download" : url.lastPathComponent
        guard save.runModal() == .OK, let path = save.url else { return }
        destination = path; downloadName = path.lastPathComponent; message = nil; downloadProgress = nil; downloading = true
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session?.downloadTask(with: url); task?.resume()
    }
    func cancelDownload() { task?.cancel(); downloading = false; downloadProgress = nil; activity = nil }
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
                files.append(destination)
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
    @State private var selected = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Tools", selection: $selected) { Text("Activities").tag(0); Text("Files").tag(1); Text("Sound").tag(2) }.pickerStyle(.segmented)
            if selected == 0 {
                HStack {
                    Label(modules.deadline == nil ? "Timer" : "\(modules.remaining / 60):\(String(format: "%02d", modules.remaining % 60))", systemImage: "timer").monospacedDigit()
                    Spacer()
                    Menu("Set") { ForEach([1, 5, 10, 25, 45, 60], id: \.self) { n in Button("\(n) minutes") { modules.startTimer(minutes: n) } }; Button("Cancel") { modules.cancelTimer() } }
                }
                if !modules.batteryText.isEmpty { Label(modules.batteryText, systemImage: "battery.100") }
                ForEach(modules.headphones, id: \.self) { Text($0).font(.caption) }
                Divider()
                TextField("HTTPS download link", text: $downloadURL).textFieldStyle(.roundedBorder)
                HStack { Button("Download…") { modules.download(downloadURL) }.disabled(modules.downloading); if modules.downloading { Button("Cancel") { modules.cancelDownload() } } }
                if modules.downloading { ProgressView(value: modules.downloadProgress); Text(modules.downloadName).font(.caption).lineLimit(1) }
                Text("Tracks downloads started here. Files are saved where you choose.").font(.caption2).foregroundStyle(.secondary)
            } else if selected == 1 {
                Text("Drop files onto the island, then drag them into another app.").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(modules.files, id: \.self) { url in
                            HStack {
                                Label(url.lastPathComponent, systemImage: "doc").lineLimit(1).onDrag { NSItemProvider(object: url as NSURL) }
                                Spacer()
                                Button { modules.files.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle") }.help("Remove from shelf; keeps original file")
                            }.padding(.vertical, 5)
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
        }.padding(.horizontal, 32).padding(.bottom, 24).foregroundStyle(.white)
            .onAppear { modules.refreshRoutes() }
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
    @AppStorage("batteryActivities") private var battery = false
    @AppStorage("headphoneActivities") private var headphones = false
    @AppStorage("animationIntensity") private var intensity = 1.0
    var body: some View {
        Section("Live Activities") {
            Toggle("Battery charging notifications", isOn: $battery)
            Toggle("AirPods and Beats connection notifications", isOn: $headphones)
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

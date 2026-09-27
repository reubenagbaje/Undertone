import AppKit
import ScreenCaptureKit
import AVFoundation
import Combine
import Accelerate
import CoreAudio

// A time-domain amplitude envelope, not a decorative or simulated equaliser.
struct EnvelopeAnalyzer {
    private var sum: Float = 0
    private var count = 0
    mutating func consume(_ samples: [Float], sampleRate: Double) -> [Float] {
        let window = max(1, Int(sampleRate / 30))
        var output: [Float] = []
        for sample in samples {
            let value = sample.isFinite ? sample : 0
            sum += value * value
            count += 1
            if count == window {
                let rms = sqrt(sum / Float(count))
                // Fixed -60...0 dB scale preserves real dynamics without automatic gain.
                output.append(rms > 0.001 ? min(1, max(0, (20 * log10(rms) + 60) / 60)) : 0)
                count = 0
                sum = 0
            }
        }
        return output
    }
}

// Signed PCM is retained for FFT analysis; taking absolute values would double
// frequencies. Each channel is transformed separately to avoid phase cancellation.
final class SpectrumAnalyzer {
    private let size = 1024
    private let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    private var pending: [[Float]] = []
    private var smoothed = [Float](repeating: 0, count: 5)
    private let edges: [Double] = [35, 180, 700, 2500, 7000, 22000]
    private lazy var window: [Float] = (0..<size).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(size - 1)) }
    deinit { vDSP_destroy_fftsetup(setup) }

    func consume(channels: [[Float]], sampleRate: Double) -> [[Float]] {
        guard sampleRate > 0, !channels.isEmpty else { return [] }
        if pending.count != channels.count { pending = channels.map { _ in [] } }
        let count = channels.map(\.count).min() ?? 0
        for channel in channels.indices {
            pending[channel].append(contentsOf: channels[channel].prefix(count).map { $0.isFinite ? $0 : 0 })
        }
        var output: [[Float]] = []
        while (pending.first?.count ?? 0) >= size {
            var powers = [Float](repeating: 0, count: size / 2)
            for channel in pending.indices {
                var real = zip(pending[channel].prefix(size), window).map(*)
                var imaginary = [Float](repeating: 0, count: size)
                real.withUnsafeMutableBufferPointer { r in
                    imaginary.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        vDSP_fft_zip(setup, &split, 1, 10, FFTDirection(FFT_FORWARD))
                    }
                }
                for bin in 1..<size / 2 { powers[bin] += (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) / Float(channels.count) }
                pending[channel].removeFirst(size)
            }
            for band in 0..<5 {
                let lo = max(1, Int(ceil(edges[band] * Double(size) / sampleRate)))
                let hi = min(size / 2, Int(ceil(edges[band + 1] * Double(size) / sampleRate)))
                let energy = hi > lo ? powers[lo..<hi].reduce(0, +) : 0
                let amplitude = sqrt(energy) * 4 / Float(size)
                let db = 20 * log10(max(0.000001, amplitude))
                let target = pow(min(1, max(0, (db + 55) / 50)), 1.35)
                smoothed[band] += (target - smoothed[band]) * (target > smoothed[band] ? 0.8 : 0.22)
                if smoothed[band] < 0.001 { smoothed[band] = 0 }
            }
            output.append(smoothed)
        }
        return output
    }
}

enum PCMReader {
    static func channels(from sample: CMSampleBuffer) throws -> ([[Float]], Double) {
        guard sample.isValid, let description = sample.formatDescription else { throw PCMError.invalid }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= Int(Int32.max), format.channelCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { throw PCMError.invalid }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { throw PCMError.copy(status) }
        return try channels(from: pcm.audioBufferList, format: format, frames: frames)
    }
    static func channels(from list: UnsafePointer<AudioBufferList>, format: AVAudioFormat, frames: Int) throws -> ([[Float]], Double) {
        guard frames > 0, format.channelCount > 0 else { throw PCMError.invalid }
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frames), count: Int(format.channelCount))
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let expectedBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        guard buffers.count >= expectedBuffers else { throw PCMError.invalid }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, buffers.prefix(expectedBuffers).allSatisfy({ Int($0.mDataByteSize) >= frames * bytesPerFrame }) else { throw PCMError.invalid }
        for channel in channels.indices {
            let buffer = buffers[format.isInterleaved ? 0 : channel]
            guard let data = buffer.mData else { throw PCMError.invalid }
            for frame in 0..<frames {
                let index = format.isInterleaved ? frame * channels.count + channel : frame
                let value: Float
                switch format.commonFormat {
                case .pcmFormatFloat32: value = data.assumingMemoryBound(to: Float.self)[index]
                case .pcmFormatFloat64: value = Float(data.assumingMemoryBound(to: Double.self)[index])
                case .pcmFormatInt16: value = Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
                case .pcmFormatInt32: value = Float(data.assumingMemoryBound(to: Int32.self)[index]) / 2147483648
                default: throw PCMError.format
                }
                channels[channel][frame] = value.isFinite ? value : 0
            }
        }
        return (channels, format.sampleRate)
    }
    enum PCMError: LocalizedError {
        case invalid, format, copy(OSStatus)
        var errorDescription: String? {
            switch self {
            case .invalid: return "Invalid audio sample buffer."
            case .format: return "Unsupported PCM sample format."
            case .copy(let status): return "Audio sample copy failed (\(status))."
            }
        }
    }
}

final class AudioSink: NSObject, SCStreamOutput, SCStreamDelegate {
    private let analyzer = SpectrumAnalyzer()
    var onLevels: (([Float], Int) -> Void)?
    var onError: ((Error) -> Void)?
    var onDecodeError: ((Error) -> Void)?
    private var reportedError = false
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // ScreenCaptureKit's display stream has an explicit screen sink, but screen
        // frames are discarded immediately. Nothing is recorded or saved.
        guard type == .audio else { return }
        do {
            let (channels, sampleRate) = try PCMReader.channels(from: sampleBuffer)
            let output = analyzer.consume(channels: channels, sampleRate: sampleRate)
            if let levels = output.last { onLevels?(levels, channels.first?.count ?? 0) }
        } catch {
            if !reportedError { reportedError = true; onDecodeError?(error) }
        }
    }
}

enum SpotifyAudioSource {
    static var selectedBundle: String {
        switch UserDefaults.standard.string(forKey: "playerSource") {
        case "Apple Music": return "com.apple.Music"
        case "Safari": return "com.apple.Safari"
        case "Chrome": return "com.google.Chrome"
        default: return "com.spotify.client"
        }
    }
    static func matches(_ bundleID: String, selected: String = "com.spotify.client") -> Bool {
        bundleID == selected || bundleID.hasPrefix(selected + ".")
    }
    @available(macOS 14.2, *)
    static func processIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { throw PCMReader.PCMError.invalid }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else { return [] }
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw PCMReader.PCMError.copy(status) }
        return ids.filter { id in
            var property = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var bundle: Unmanaged<CFString>?
            var length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &length, &bundle) == noErr, let bundle else { return false }
            return matches(bundle.takeRetainedValue() as String, selected: selectedBundle)
        }.sorted()
    }
}

// macOS 14.2+: this path captures only audio, without asking ScreenCaptureKit to
// enumerate screens/windows. A private tap/aggregate is destroyed on stop.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Undertone.coreaudio", qos: .userInitiated)
    private let analyzer = SpectrumAnalyzer()

    @available(macOS 14.2, *)
    func start(processes: [AudioObjectID], onLevels: @escaping ([Float], Int) -> Void, onError: @escaping (Error) -> Void) throws {
        guard !processes.isEmpty else { throw PCMReader.PCMError.invalid }
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Undertone Spotify Audio"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        do {
            try check(AudioHardwareCreateProcessTap(description, &tapID), "Create system audio tap")
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "Read audio format")
            guard let format = AVAudioFormat(streamDescription: &asbd), format.sampleRate > 0 else { throw PCMReader.PCMError.format }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Undertone Audio",
                kAudioAggregateDeviceUIDKey: "dev.reuben.Undertone.audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "Create audio capture device")
            var reportedError = false
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, queue) { [weak self] _, input, _, _, _ in
                guard let self else { return }
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
                guard bytesPerFrame > 0, let first = buffers.first, first.mDataByteSize > 0 else { return }
                do {
                    let count = Int(first.mDataByteSize) / bytesPerFrame
                    let (channels, rate) = try PCMReader.channels(from: input, format: format, frames: count)
                    let output = self.analyzer.consume(channels: channels, sampleRate: rate)
                    if let levels = output.last { onLevels(levels, count) }
                } catch {
                    if !reportedError { reportedError = true; onError(error) }
                }
            }, "Install audio callback")
            try check(AudioDeviceStart(deviceID, ioProc), "Start audio capture")
        } catch {
            stop()
            throw error
        }
    }
    func stop() {
        if let ioProc, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
    deinit { stop() }
    private func check(_ status: OSStatus, _ action: String) throws {
        if status != noErr { throw NSError(domain: "Undertone.Audio", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(action) failed (\(status))."]) }
    }
}

@MainActor final class AudioCapture: ObservableObject {
    @Published private(set) var levels = [Float](repeating: 0, count: 5)
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var receivedFrames = 0
    @Published private(set) var hasSignal = false
    @Published private(set) var peakLevel: Float = 0
    @Published private(set) var message = "Enable live audio to see your music."
    private var stream: SCStream?
    private var sink: AudioSink?
    private var nativeTap: SystemAudioTap?
    private let queue = DispatchQueue(label: "Undertone.audio", qos: .userInitiated)
    private var lastSample = Date.distantPast
    private var watchdog: Timer?
    private var generation = UUID()
    private var processMonitor: Timer?
    private var capturedProcesses: [AudioObjectID] = []
    private var displaySleeping = false
    private var suspensionTask: Task<Void, Never>?

    func setDisplaySleeping(_ value: Bool) {
        displaySleeping = value
        suspensionTask?.cancel()
        suspensionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.busy {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            if self.displaySleeping {
                let enabled = UserDefaults.standard.bool(forKey: "captureEnabled")
                await self.stop()
                UserDefaults.standard.set(enabled, forKey: "captureEnabled")
            } else { await self.resumeIfEnabled() }
        }
    }


    func resumeIfEnabled() async {
        if UserDefaults.standard.bool(forKey: "captureEnabled") { await start() }
    }

    func restart() async {
        await stop()
        await start()
    }

    func start() async {
        guard !busy, !running, !displaySleeping else { return }
        busy = true
        UserDefaults.standard.set(true, forKey: "captureEnabled")
        monitorSpotifyProcesses()
        receivedFrames = 0
        peakLevel = 0
        defer { busy = false }
        let token = UUID()
        generation = token
        do {
            if #available(macOS 14.2, *) {
                capturedProcesses = try SpotifyAudioSource.processIDs()
                guard !capturedProcesses.isEmpty else {
                    message = "Waiting for the selected player. Play audio on this Mac."
                    return
                }
                let tap = SystemAudioTap()
                try tap.start(processes: capturedProcesses, onLevels: { [weak self] values, frames in
                    Task { @MainActor in self?.receive(values, frames: frames, token: token) }
                }, onError: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.message = error.localizedDescription + " Try Restart audio."
                    }
                })
                nativeTap = tap
                beginMonitoring()
                return
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !displaySleeping else { return }
            guard let display = content.displays.first else { throw CaptureError.noDisplay }
            let applications = content.applications.filter { SpotifyAudioSource.matches($0.bundleIdentifier, selected: SpotifyAudioSource.selectedBundle) }
            guard !applications.isEmpty else { throw CaptureError.noSpotify }
            let filter = SCContentFilter(display: display, including: applications, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // Register a minimal screen sink as well; frames are immediately discarded.
            config.width = 16
            config.height = 16
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3
            let receiver = AudioSink()
            receiver.onLevels = { [weak self] values, frames in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.receive(values, frames: frames, token: token)
                }
            }
            receiver.onDecodeError = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.message = error.localizedDescription + " Use Restart audio below."
                }
            }
            receiver.onError = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.reset()
                    self.message = "Capture stopped: \(error.localizedDescription). Try enabling it again."
                }
            }
            let capture = SCStream(filter: filter, configuration: config, delegate: receiver)
            try capture.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: queue)
            try capture.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: queue)
            sink = receiver
            stream = capture
            try await capture.startCapture()
            beginMonitoring()
        } catch CaptureError.noSpotify {
            reset()
            message = "Open the selected player on this Mac, then enable audio again."
        } catch {
            reset()
            message = "Audio unavailable: \(error.localizedDescription) Allow this build of Undertone in Privacy & Security → Screen & System Audio Recording (System Audio Recording on newer macOS), then retry or relaunch."
        }
    }

    private func monitorSpotifyProcesses() {
        guard processMonitor == nil else { return }
        processMonitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy, !self.displaySleeping, UserDefaults.standard.bool(forKey: "captureEnabled") else { return }
                if #available(macOS 14.2, *), let ids = try? SpotifyAudioSource.processIDs(), ids != self.capturedProcesses {
                    await self.restart()
                }
            }
        }
        if let processMonitor { RunLoop.main.add(processMonitor, forMode: .common) }
    }

    private func receive(_ values: [Float], frames: Int, token: UUID) {
        guard generation == token, !displaySleeping else { return }
        lastSample = Date()
        levels = values
        peakLevel = max(peakLevel, values.max() ?? 0)
        receivedFrames += frames
        hasSignal = values.contains { $0 > 0.015 }
        message = hasSignal ? "Receiving selected-player audio" : "Receiving audio • currently silent"
    }

    private func beginMonitoring() {
            running = true
            lastSample = Date()
            message = "Live • selected player"
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.running else { return }
                    if Date().timeIntervalSince(self.lastSample) > 0.2 {
                        self.levels = self.levels.map { $0 < 0.01 ? 0 : $0 * 0.65 }
                        self.hasSignal = false
                        if Date().timeIntervalSince(self.lastSample) > 3 {
                            self.message = "No audio buffers received. Play the selected player on this Mac, then try Restart audio. If it stays flat, quit and reopen Undertone after checking Screen & System Audio Recording permission."
                        }
                    }
                }
            }
            if let watchdog { RunLoop.main.add(watchdog, forMode: .common) }
    }

    func stop() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if let stream {
            do { try await stream.stopCapture() }
            catch { message = "Could not stop capture: \(error.localizedDescription). Quit Undertone to end capture."; return }
        }
        reset()
        processMonitor?.invalidate()
        processMonitor = nil
        capturedProcesses = []
        UserDefaults.standard.set(false, forKey: "captureEnabled")
        message = "Audio capture is off."
    }

    private func reset() {
        generation = UUID()
        watchdog?.invalidate()
        watchdog = nil
        nativeTap?.stop()
        nativeTap = nil
        running = false
        hasSignal = false
        stream = nil
        sink = nil
        levels = [Float](repeating: 0, count: 5)
    }
    private enum CaptureError: LocalizedError {
        case noDisplay, noSpotify
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display is available for audio capture."
            case .noSpotify: return "Open the selected player on this Mac, then enable audio again."
            }
        }
    }
}

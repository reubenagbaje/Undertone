import Foundation
import CoreGraphics

struct SpotifyReconnectPolicy {
    private(set) var failures = 0
    private(set) var retryAt: TimeInterval = 0
    private(set) var permissionDenied = false
    mutating func failed(code: Int?, now: TimeInterval) {
        permissionDenied = code == -1743
        failures += 1
        retryAt = now + min(30, pow(2, Double(min(failures, 5))))
    }
    mutating func reset() { self = Self() }
    func allowsAttempt(at time: TimeInterval) -> Bool { !permissionDenied && time >= retryAt }
}

struct TimedLyric: Identifiable, Equatable, Codable {
    var id: Int
    var time: Double
    var text: String
}

enum LRCParser {
    static func parse(_ input: String) -> [TimedLyric] {
        let timestamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2})(?:\.(\d{1,3}))?\]"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        let ns = input as NSString
        let match = offsetPattern.firstMatch(in: input, range: NSRange(location: 0, length: ns.length))
        let offset = match.flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        var output: [(Double, String)] = []
        for line in input.components(separatedBy: .newlines) {
            let text = line as NSString
            let matches = timestamp.matches(in: line, range: NSRange(location: 0, length: text.length))
            guard let last = matches.last else { continue }
            let words = text.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(text.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(text.substring(with: match.range(at: 2))) ?? 0
                guard seconds < 60 else { continue }
                let fraction = match.range(at: 3).location == NSNotFound ? 0 : Double("0." + text.substring(with: match.range(at: 3))) ?? 0
                output.append((max(0, minutes * 60 + seconds + fraction + offset), words))
            }
        }
        return output.enumerated().sorted { $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0 }
            .enumerated().map { TimedLyric(id: $0.offset, time: $0.element.element.0, text: $0.element.element.1) }
    }
    static func activeIndex(in lines: [TimedLyric], position: Double) -> Int? {
        guard position.isFinite else { return nil }
        return lines.lastIndex { $0.time <= position }
    }
}

// No playback may create an overlay, and a sleeping display never renders it.
struct LockPresentationPolicy {
    var enabled = false
    var locked = false
    var asleep = false
    var sessionActive = true
    var playing = false
    var preview = false
    var shouldPresent: Bool { !asleep && sessionActive && (preview && !locked || enabled && locked && playing) }
}

// Reserve the lower authentication area while centring the player above it.
struct LockPlayerLayout {
    var size: CGSize
    var locked: Bool
    var loginArea: CGRect { CGRect(x: 0, y: size.height * 0.78, width: size.width, height: size.height * 0.22) }
    var controls: CGRect {
        let width = min(locked ? 370 : 420, size.width - 48)
        let height = (width - 38) / 360 * 189 + 24
        let bottom = locked ? loginArea.minY - 18 : size.height - 42
        return CGRect(x: (size.width - width) / 2,
                      y: max(24, bottom - height), width: width, height: height)
    }
    func permitsInteraction(at point: CGPoint, expanded: Bool) -> Bool {
        guard CGRect(origin: .zero, size: size).contains(point) else { return false }
        if locked && loginArea.contains(point) { return false }
        return expanded || controls.insetBy(dx: -6, dy: -6).contains(point)
    }
}

// Reject position samples taken before/during a seek, including rapid seeks.
struct PlaybackSeekState {
    private(set) var revision = 0
    private(set) var pending = false
    mutating func begin() -> Int { revision += 1; pending = true; return revision }
    mutating func complete(_ token: Int) -> Bool {
        guard token == revision else { return false }
        pending = false
        return true
    }
    func accepts(revision sample: Int, pendingAtStart: Bool) -> Bool {
        sample == revision && !pending && !pendingAtStart
    }
}

struct SleepSchedule {
    private(set) var deadline: Date?
    mutating func start(minutes: Int, now: Date = Date()) {
        deadline = minutes > 0 ? now.addingTimeInterval(Double(minutes) * 60) : nil
    }
    mutating func cancel() { deadline = nil }
    mutating func consumeExpiration(now: Date = Date()) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }
}

/// Downloads are explicit HTTPS transfers, without credentials embedded in links.
enum ActivityDownloadURL {
    static func parse(_ input: String) -> URL? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

/// Deadline-based countdown: pausing preserves fractional seconds; sleep does not delay completion.
struct ActivityCountdown {
    private(set) var duration: TimeInterval = 0
    private(set) var deadline: Date?
    private(set) var pausedRemaining: TimeInterval = 0
    private(set) var finished = false
    var active: Bool { deadline != nil || pausedRemaining > 0 || finished }
    var paused: Bool { deadline == nil && pausedRemaining > 0 }
    func seconds(at now: Date) -> TimeInterval { max(0, deadline?.timeIntervalSince(now) ?? pausedRemaining) }
    func remaining(at now: Date) -> Int { Int(ceil(seconds(at: now))) }
    func progress(at now: Date) -> Double { duration > 0 ? min(1, seconds(at: now) / duration) : 0 }
    mutating func start(seconds: TimeInterval, now: Date) {
        guard seconds.isFinite, seconds > 0 else { cancel(); return }
        duration = seconds; deadline = now.addingTimeInterval(seconds); pausedRemaining = 0; finished = false
    }
    mutating func togglePause(now: Date) {
        if paused { deadline = now.addingTimeInterval(pausedRemaining); pausedRemaining = 0 }
        else if deadline != nil { pausedRemaining = seconds(at: now); deadline = nil; if pausedRemaining == 0 { finished = true } }
    }
    mutating func consumeExpiration(now: Date) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil; pausedRemaining = 0; finished = true; return true
    }
    mutating func cancel() { deadline = nil; pausedRemaining = 0; finished = false }
    static func formatted(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The drag pasteboard outlives a drag. Only a fresh change while the button is held
/// is evidence of a new drag; clicks on playback controls must never reuse it.
struct FileDragIntent {
    private var previousChange: Int?
    private(set) var active = false
    mutating func update(change: Int, buttonDown: Bool, containsFiles: Bool) -> Bool {
        defer { previousChange = change }
        guard buttonDown else { active = false; return false }
        if let previousChange, change != previousChange { active = containsFiles }
        return active && containsFiles
    }
}

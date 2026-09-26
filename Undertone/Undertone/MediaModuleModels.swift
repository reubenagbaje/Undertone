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

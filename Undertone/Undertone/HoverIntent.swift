import Foundation

// A continuous dwell is required: crossing the notch never opens the player.
struct HoverIntent {
    var delay: TimeInterval = 0.5
    private(set) var previewing = false
    private var enteredAt: TimeInterval?
    private var fired = false
    mutating func update(inside: Bool, now: TimeInterval) -> Bool {
        guard inside else { enteredAt = nil; fired = false; previewing = false; return false }
        if enteredAt == nil { enteredAt = now }
        previewing = now - (enteredAt ?? now) >= 0.08
        guard !fired, now - (enteredAt ?? now) >= delay else { return false }
        fired = true
        return true
    }
}

// A swipe is a reversible drag until fingers lift. Momentum never commits.
struct SwipeIntent {
    enum Direction: Equatable {
        case left, right
        func skipsForward(reversed: Bool) -> Bool { (self == .left) != reversed }
    }
    var threshold: Double = 60
    private var x: Double = 0
    private var y: Double = 0
    private(set) var active = false
    private(set) var claimed = false
    var visualTravel: Double { claimed ? x / threshold : 0 }
    var progress: Double { claimed ? min(1, max(-1, x / threshold)) : 0 }
    mutating func reset() { x = 0; y = 0; active = false; claimed = false }
    mutating func consume(dx: Double, dy: Double, began: Bool, momentum: Bool) {
        guard !momentum else { return }
        if began { reset(); active = true }
        guard active else { return }
        x += dx; y += dy
        if abs(x) > 3 && abs(x) > abs(y) * 1.5 { claimed = true }
    }
    mutating func finish(cancelled: Bool = false) -> Direction? {
        defer { reset() }
        guard active, claimed, !cancelled, abs(x) >= threshold, abs(x) > abs(y) * 1.5 else { return nil }
        return x < 0 ? .left : .right
    }
}

// Monotonic-time preview lifecycle. New tracks replace and renew the notice;
// pausing alone does not cut its closing animation short.
struct TrackNoticeIntent {
    var duration: TimeInterval = 3
    private(set) var text: String?
    private var deadline: TimeInterval = 0
    mutating func show(_ text: String, now: TimeInterval) {
        self.text = text
        deadline = now + duration
    }
    mutating func update(now: TimeInterval, dismiss: Bool = false) {
        if dismiss || now >= deadline { text = nil }
    }
}

// Continuous presentation: reversing the fingers also reverses every visual.
struct SwipePresentation {
    let progress: Double
    let reversed: Bool
    var amount: Double { min(1, abs(progress)) }
    var forward: Bool { (progress < 0) != reversed }
    var forwardAmount: Double { forward ? amount : 0 }
    var backwardAmount: Double { forward ? 0 : amount }
    var reveal: Double {
        let t = min(1, amount / 0.5)
        return t * t * (3 - 2 * t)
    }
    var forwardReveal: Double { forward ? reveal : 0 }
    var backwardReveal: Double { forward ? 0 : reveal }
    var extensionWidth: Double { amount * 6 + 5 * (1 - exp(-max(0, abs(progress) - 1))) }
    // Symbols travel from the camera toward their action edge, rather than
    // entering from outside the island. Both directions are exact mirrors.
    var forwardIconOffset: Double { -12 * (1 - forwardReveal) + (forward ? extensionWidth * 2 / 3 : 0) }
    var backwardIconOffset: Double { 12 * (1 - backwardReveal) - (forward ? 0 : extensionWidth * 2 / 3) }
    var coverOpacity: Double { 1 - reveal * (forward ? 0.65 : 1) }
}

// CGRect.contains excludes its maximum edges; the physical screen edge is a
// valid hover location, including when the pointer disappears behind the camera.
enum NotchHitTarget {
    static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX &&
        point.y >= rect.minY && point.y <= rect.maxY
    }
}

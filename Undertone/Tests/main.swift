import Foundation

func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
var silence = EnvelopeAnalyzer()
require(silence.consume([Float](repeating: 0, count: 4800), sampleRate: 48000) == [0, 0, 0], "Silence must be flat")
var fullScale = EnvelopeAnalyzer()
require(fullScale.consume([Float](repeating: 1, count: 1600), sampleRate: 48000) == [1], "Full-scale amplitude")
var quiet = EnvelopeAnalyzer()
let quietValue = quiet.consume([Float](repeating: 0.01, count: 1600), sampleRate: 48000)[0]
require(abs(quietValue - 1 / Float(3)) < 0.001, "-40 dB mapping")
var chunked = EnvelopeAnalyzer()
require(chunked.consume([Float](repeating: 0.1, count: 800), sampleRate: 48000).isEmpty, "Carry partial windows")
require(chunked.consume([Float](repeating: 0.1, count: 800), sampleRate: 48000).count == 1, "Finish carried window")
var invalid = EnvelopeAnalyzer()
let values = invalid.consume([Float](repeating: .nan, count: 1600), sampleRate: 48000)
require(values == [0], "Non-finite input must not poison waveform")
var dynamics = EnvelopeAnalyzer()
let signal = (0..<4800).map { i -> Float in
    let gain: Float = i < 1600 ? 0.02 : i < 3200 ? 0.8 : 0
    return gain * sin(Float(i) * 2 * .pi * 440 / 48000)
}
let result = dynamics.consume(signal, sampleRate: 48000)
require(result.count == 3 && result[1] > result[0] && result[2] == 0, "Loud music must exceed quiet music and settle to silence")
print("PASS: silence, full scale, dB mapping, buffer boundaries, invalid values, dynamic signal")

import AVFoundation
import CoreMedia

func audioSample(format: AVAudioFormat, frameCount: Int) -> CMSampleBuffer {
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
    pcm.frameLength = AVAudioFrameCount(frameCount)
    let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
    for channel in 0..<Int(format.channelCount) {
        let buffer = buffers[format.isInterleaved ? 0 : channel]
        for frame in 0..<frameCount {
            let index = format.isInterleaved ? frame * Int(format.channelCount) + channel : frame
            let value = Float(sin(Double(frame) * 2 * .pi * 440 / format.sampleRate) * (channel == 0 ? 0.5 : -0.5))
            switch format.commonFormat {
            case .pcmFormatFloat32: buffer.mData!.assumingMemoryBound(to: Float.self)[index] = value
            case .pcmFormatFloat64: buffer.mData!.assumingMemoryBound(to: Double.self)[index] = Double(value)
            case .pcmFormatInt16: buffer.mData!.assumingMemoryBound(to: Int16.self)[index] = Int16(value * 32767)
            case .pcmFormatInt32: buffer.mData!.assumingMemoryBound(to: Int32.self)[index] = Int32(Double(value) * 2147483647)
            default: fatalError("unsupported test format")
            }
        }
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(format.sampleRate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let created = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                      formatDescription: format.formatDescription, sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
    require(created == noErr, "Create CMSampleBuffer")
    let copied = CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList)
    require(copied == noErr, "Populate CMSampleBuffer")
    CMSampleBufferSetDataReady(sample!)
    return sample!
}

for commonFormat in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32] {
    for interleaved in [false, true] {
        let format = AVAudioFormat(commonFormat: commonFormat, sampleRate: 48000, channels: 2, interleaved: interleaved)!
        let (channels, rate) = try PCMReader.channels(from: audioSample(format: format, frameCount: 4096))
        require(channels.count == 2 && channels[0].count == 4096 && rate == 48000, "PCM format/frame count")
        require(abs(channels[0][50] + channels[1][50]) < 0.0001, "Stereo polarity retained")
        require(channels[0].contains { abs($0) > 0.4 }, "Real PCM samples decoded")
        let bands = SpectrumAnalyzer().consume(channels: channels, sampleRate: rate).last!
        require(bands[1] > 0.7 && bands[1] > bands[3], "Anti-phase stereo tone must still light the correct frequency band")
    }
}
let spectrum = SpectrumAnalyzer()
func tone(_ frequency: Double, gain: Float = 0.5, count: Int = 4096) -> [Float] {
    (0..<count).map { gain * Float(sin(Double($0) * 2 * .pi * frequency / 48000)) }
}
let low = SpectrumAnalyzer().consume(channels: [tone(93.75)], sampleRate: 48000).last!
let high = SpectrumAnalyzer().consume(channels: [tone(9000)], sampleRate: 48000).last!
require(low[0] > 0.7 && low[0] > low[4], "Bass drives left band")
require(high[4] > 0.7 && high[4] > high[0], "Treble drives right band")
let partial = SpectrumAnalyzer()
require(partial.consume(channels: [tone(440, count: 512)], sampleRate: 48000).isEmpty, "FFT buffers short callbacks")
require(partial.consume(channels: [tone(440, count: 512)], sampleRate: 48000).count == 1, "FFT handles split frames")
_ = spectrum.consume(channels: [tone(440)], sampleRate: 48000)
let silent = spectrum.consume(channels: [[Float](repeating: 0, count: 48000)], sampleRate: 48000).last!
require(silent.allSatisfy { $0 == 0 }, "Bands settle to zero in silence")
var dwell = HoverIntent()
require(!dwell.update(inside: true, now: 0), "Entering does not immediately open")
require(!dwell.previewing, "Entry does not flash preview")
require(!dwell.update(inside: true, now: 0.2) && dwell.previewing, "Preview precedes full expansion")
require(!dwell.update(inside: false, now: 0.21) && !dwell.previewing, "Leaving cancels dwell and preview")
require(!dwell.update(inside: true, now: 1), "Reentry starts a new dwell")
require(dwell.update(inside: true, now: 1.51), "Continuous hover opens after 500ms")
require(!dwell.update(inside: true, now: 1.6), "A single entry only fires once")
print("PASS: 8 PCM layouts through CMSampleBuffer → decoder → spectrum, stereo phase, bass/treble separation, FFT boundaries, silence decay, hover dwell/cancellation")
var swipe = SwipeIntent()
swipe.consume(dx: -2, dy: 0, began: true, momentum: false)
require(!swipe.claimed, "Ignore tiny finger jitter")
swipe.consume(dx: -20, dy: 0, began: false, momentum: false)
require(swipe.claimed && swipe.progress < 0, "Partial swipe previews direction")
require(swipe.finish() == nil, "Partial swipe does not commit on lift")
swipe.consume(dx: -90, dy: 0, began: true, momentum: false)
require(swipe.active && swipe.progress == -1, "Threshold only arms while fingers remain down")
swipe.consume(dx: 80, dy: 0, began: false, momentum: false)
require(swipe.finish() == nil, "Dragging back below threshold cancels an armed swipe")
swipe.consume(dx: 90, dy: 0, began: true, momentum: false)
swipe.consume(dx: -85, dy: 0, began: false, momentum: false)
require(swipe.finish() == nil, "Reverse-direction drag back also cancels")
swipe.consume(dx: -65, dy: 0, began: true, momentum: false)
require(swipe.finish() == .left, "Release beyond left threshold commits once")
require(swipe.finish() == nil, "Repeated end cannot skip twice")
swipe.consume(dx: 90, dy: 0, began: true, momentum: true)
require(swipe.finish() == nil, "Momentum cannot begin or commit a gesture")
swipe.consume(dx: 70, dy: 0, began: true, momentum: false)
require(swipe.finish() == .right, "Right release commits restart or previous")
swipe.consume(dx: 80, dy: 0, began: true, momentum: false)
require(swipe.finish(cancelled: true) == nil, "System cancellation never commits")
swipe.consume(dx: 10, dy: 90, began: true, momentum: false)
require(!swipe.claimed && swipe.finish() == nil, "Vertical scroll cannot skip")
swipe.consume(dx: -70, dy: 0, began: true, momentum: false)
swipe.consume(dx: 150, dy: 0, began: false, momentum: false)
require(swipe.finish() == .right, "Crossing through centre commits the final direction only")
require(SwipeIntent.Direction.left.skipsForward(reversed: false) && !SwipeIntent.Direction.right.skipsForward(reversed: false), "Default swipe mapping")
require(!SwipeIntent.Direction.left.skipsForward(reversed: true) && SwipeIntent.Direction.right.skipsForward(reversed: true), "Reversed swipe mapping")
print("PASS: release-to-commit, partial/armed reversal cancellation, both directions, momentum, system cancellation, vertical rejection, reverse mapping")

var notice = TrackNoticeIntent()
notice.show("Artist • First", now: 10)
notice.update(now: 12.9)
require(notice.text == "Artist • First", "Caption stays for the full reading interval")
notice.show("Artist • Second", now: 12.9)
notice.update(now: 13.1)
require(notice.text == "Artist • Second", "Rapid skip replaces caption and renews its deadline")
notice.update(now: 15.91)
require(notice.text == nil, "Caption retracts after three seconds")
notice.show("Artist • Third", now: 20)
notice.update(now: 20.1, dismiss: true)
require(notice.text == nil, "Opening full player dismisses preview")
notice.update(now: 21)
require(notice.text == nil, "Dismissed caption cannot reappear")
print("PASS: preview lifetime, rapid-skip replacement, deadline renewal, dismissal")

for reversed in [false, true] {
    for direction in [-1.0, 1.0] {
        let rest = SwipePresentation(progress: 0, reversed: reversed)
        let half = SwipePresentation(progress: direction * 0.5, reversed: reversed)
        let full = SwipePresentation(progress: direction, reversed: reversed)
        assert(rest.extensionWidth == 0 && rest.coverOpacity == 1)
        assert(half.extensionWidth == 3 && full.extensionWidth == 6)
        assert(half.forwardAmount + half.backwardAmount == 0.5)
        assert(full.forwardAmount + full.backwardAmount == 1)
        assert(half.coverOpacity >= full.coverOpacity)
        assert(full.forward == ((direction < 0) != reversed))
    }
}
print("PASS: continuous swipe presentation and reversed action side")

let cameraRect = CGRect(x: 640, y: 964, width: 180, height: 36)
assert(NotchHitTarget.contains(CGPoint(x: 730, y: 1000), in: cameraRect))
assert(NotchHitTarget.contains(CGPoint(x: 820, y: 1000), in: cameraRect))
assert(!NotchHitTarget.contains(CGPoint(x: 730, y: 1001), in: cameraRect))
assert(!NotchHitTarget.contains(CGPoint(x: 730, y: 950), in: cameraRect))
var edgeDwell = HoverIntent()
assert(!edgeDwell.update(inside: NotchHitTarget.contains(CGPoint(x: 730, y: 1000), in: cameraRect), now: 0))
assert(edgeDwell.update(inside: NotchHitTarget.contains(CGPoint(x: 730, y: 1000), in: cameraRect), now: 0.51))
print("PASS: physical top-edge hover and dwell")

assert(SpotifyAudioSource.matches("com.spotify.client"))
assert(SpotifyAudioSource.matches("com.spotify.client.helper"))
assert(!SpotifyAudioSource.matches("com.spotify.clientfake"))
assert(!SpotifyAudioSource.matches("com.apple.Safari"))
assert(!SpotifyAudioSource.matches(""))
print("PASS: Spotify-only source allowlist rejects unrelated apps")

for step in 0...60 {
    let p = Double(step) / 60
    let next = SwipePresentation(progress: -p, reversed: false)
    let previous = SwipePresentation(progress: p, reversed: false)
    assert(abs(next.forwardIconOffset + previous.backwardIconOffset) < 0.00001)
    if step > 0 {
        let earlier = SwipePresentation(progress: -(p - 1.0 / 60), reversed: false)
        assert(next.forwardIconOffset > earlier.forwardIconOffset)
    }
}
print("PASS: mirrored outward symbol travel through 61 gesture positions")

var elasticGesture = SwipeIntent()
elasticGesture.consume(dx: -120, dy: 0, began: true, momentum: false)
assert(elasticGesture.progress == -1 && elasticGesture.visualTravel == -2)
let armedVisual = SwipePresentation(progress: -1, reversed: false)
let stretchedVisual = SwipePresentation(progress: elasticGesture.visualTravel, reversed: false)
assert(stretchedVisual.extensionWidth > armedVisual.extensionWidth && stretchedVisual.extensionWidth < 11)
assert(SwipePresentation(progress: -0.5, reversed: false).forwardReveal == 1)
elasticGesture.consume(dx: 110, dy: 0, began: false, momentum: false)
assert(elasticGesture.finish() == nil)
print("PASS: early symbol reveal, elastic overtravel and cancellation after overtravel")

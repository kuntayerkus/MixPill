import Foundation
import AVFoundation
import Accelerate

// Standalone checks for the core DSP primitives, compiled directly against
// the engine sources. Focused on the paths that were corrupting memory.

var failures = 0
var checks = 0

@MainActor func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    if condition() {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)")
    }
}

func makeBuffer(frames: Int, fill: (Int, Int) -> Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = buffer.floatChannelData!
    for channel in 0..<2 {
        for frame in 0..<frames {
            data[channel][frame] = fill(channel, frame)
        }
    }
    return buffer
}

func drain(_ ring: RingBufferManager, frames: Int) -> [[Float]] {
    var left = [Float](repeating: -999, count: frames)
    var right = [Float](repeating: -999, count: frames)
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            var pointers: [UnsafeMutablePointer<Float>?] = [l.baseAddress, r.baseAddress]
            ring.read(frameCount: frames, intoPlanar: &pointers, channelCount: 2)
        }
    }
    return [left, right]
}

// ── Ring buffer ───────────────────────────────────────────────────────────

print("RingBufferManager")

do {
    // Roundtrip: what goes in comes out, in order.
    let ring = RingBufferManager(capacityFrames: 1024, channelCount: 2)
    ring.write(from: makeBuffer(frames: 256) { channel, frame in Float(frame) + Float(channel) * 1000 })
    let out = drain(ring, frames: 256)
    check("roundtrip preserves left channel", out[0] == (0..<256).map { Float($0) })
    check("roundtrip preserves right channel", out[1] == (0..<256).map { Float($0) + 1000 })
    check("ring is empty after full read", ring.availableFrames == 0)
}

do {
    // Underrun pads with silence rather than stale data.
    let ring = RingBufferManager(capacityFrames: 1024, channelCount: 2)
    ring.write(from: makeBuffer(frames: 64) { _, _ in 0.5 })
    let out = drain(ring, frames: 256)
    check("underrun keeps real frames", Array(out[0][0..<64]) == [Float](repeating: 0.5, count: 64))
    check("underrun silence-pads remainder", Array(out[0][64..<256]) == [Float](repeating: 0, count: 192))
}

do {
    // Wrap-around: head crosses the end of storage mid-write.
    let ring = RingBufferManager(capacityFrames: 512, channelCount: 2)
    ring.write(from: makeBuffer(frames: 400) { _, _ in 1 })
    _ = drain(ring, frames: 400)
    ring.write(from: makeBuffer(frames: 300) { _, frame in Float(frame) })
    let out = drain(ring, frames: 300)
    check("wrapped write reads back in order", out[0] == (0..<300).map { Float($0) })
}

do {
    // The regression: a producer block larger than the whole ring. Before
    // the clamp this ran memcpy past the end of the storage allocation.
    let ring = RingBufferManager(capacityFrames: 512, channelCount: 2)
    let oversized = 4096
    ring.write(from: makeBuffer(frames: oversized) { _, frame in Float(frame) })
    check("oversized write does not exceed capacity", ring.availableFrames <= ring.capacity)
    let out = drain(ring, frames: ring.capacity)
    // Newest `capacity` frames survive; the oldest are dropped.
    let expected = (oversized - ring.capacity..<oversized).map { Float($0) }
    check("oversized write keeps the newest frames", out[0] == expected)
}

do {
    // Repeated oversized writes must stay stable (heap corruption would
    // usually surface here).
    let ring = RingBufferManager(capacityFrames: 512, channelCount: 2)
    for iteration in 0..<200 {
        ring.write(from: makeBuffer(frames: 1024 + iteration % 7) { _, frame in Float(frame) })
        _ = drain(ring, frames: 128)
    }
    check("repeated oversized writes stay bounded", ring.availableFrames <= ring.capacity)
}

// ── EQ coefficient design ─────────────────────────────────────────────────

print("BiquadDesigner")

do {
    check("all-flat gains disable the EQ",
          BiquadDesigner.peakingCoefficients(gains: [0, 0, 0, 0, 0], sampleRate: 48000) == nil)

    // The regression: section count must not depend on how many bands are
    // non-flat, because the vDSP setup is allocated for a fixed count.
    let one = BiquadDesigner.peakingCoefficients(gains: [6, 0, 0, 0, 0], sampleRate: 48000)
    let five = BiquadDesigner.peakingCoefficients(gains: [1, 2, 3, 4, 5], sampleRate: 48000)
    check("one non-flat band still designs a full cascade", one != nil)
    check("five non-flat bands design a full cascade", five != nil)
    check("flat band is a pass-through section", one?.section(1) == [1, 0, 0, 0, 0])
    check("non-flat band is not pass-through", one?.section(0) != [1, 0, 0, 0, 0])
    check("short gain arrays are tolerated",
          BiquadDesigner.peakingCoefficients(gains: [6], sampleRate: 48000) != nil)
    check("coefficient block is exactly 5 sections of 5", EQCoefficients.floatCount == 25)

    // The block is inline storage, so it must survive a copy through the
    // parameter struct without losing or shifting a coefficient.
    if let five {
        var params = ChannelDSPParameters.flat
        params.eqCoefficients = five
        let copied = params.eqCoefficients
        check("coefficients round-trip through the parameter block",
              (0..<EQCoefficients.floatCount).allSatisfy { copied[$0] == five[$0] })
        check("identical designs compare equal",
              BiquadDesigner.peakingCoefficients(gains: [1, 2, 3, 4, 5], sampleRate: 48000) == five)
        check("different designs compare unequal",
              BiquadDesigner.peakingCoefficients(gains: [1, 2, 3, 4, 6], sampleRate: 48000) != five)
    }
}

// ── Channel DSP ───────────────────────────────────────────────────────────

print("ChannelStripDSP")

func runDSP(_ dsp: ChannelStripDSP, input: [Float], frames: Int) -> [Float] {
    var left = input
    var right = input
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            dsp.process(left: l.baseAddress!, right: r.baseAddress!, frameCount: frames, sampleRate: 48000)
        }
    }
    return left
}

do {
    var params = ChannelDSPParameters.flat
    params.volume = 0.5
    let dsp = ChannelStripDSP(initial: params)
    let out = runDSP(dsp, input: [Float](repeating: 1.0, count: 256), frames: 256)
    check("volume scales the block", out.allSatisfy { abs($0 - 0.5) < 1e-6 })
}

do {
    var params = ChannelDSPParameters.flat
    params.isMuted = true
    let dsp = ChannelStripDSP(initial: params)
    let out = runDSP(dsp, input: [Float](repeating: 1.0, count: 256), frames: 256)
    check("mute silences the block", out.allSatisfy { $0 == 0 })
}

do {
    // The corruption scenario: switch the EQ between different numbers of
    // non-flat bands while rendering. With a variable section count this
    // wrote past the vDSP setup.
    var params = ChannelDSPParameters.flat
    params.eqEnabled = true
    params.eqCoefficients = BiquadDesigner.peakingCoefficients(gains: [6, 0, 0, 0, 0], sampleRate: 48000)!
    params.generation = 1
    let dsp = ChannelStripDSP(initial: params)
    _ = runDSP(dsp, input: [Float](repeating: 0.25, count: 256), frames: 256)

    let gainSets: [[Float]] = [[6, 0, 0, 0, 0], [6, 3, -2, 0, 0], [0, 0, 0, 0, 9], [1, 2, 3, 4, 5], [0, 0, 4, 0, 0]]
    var generation: UInt64 = 1
    for gains in gainSets {
        generation += 1
        var next = dsp.parameters.load()
        next.eqCoefficients = BiquadDesigner.peakingCoefficients(gains: gains, sampleRate: 48000)!
        next.generation = generation
        dsp.parameters.store(next)
        let out = runDSP(dsp, input: (0..<256).map { sinf(Float($0) * 0.1) * 0.25 }, frames: 256)
        check("EQ band-count change \(gains) stays finite", out.allSatisfy { $0.isFinite })
    }
}

// ── Gain continuity ───────────────────────────────────────────────────────

print("Gain ramping")

/// Renders `blocks` consecutive blocks through one DSP instance, changing
/// the parameters between them, and returns the concatenated output.
func renderBlocks(_ dsp: ChannelStripDSP, blocks: [(ChannelDSPParameters?, [Float])], frames: Int) -> [Float] {
    var output: [Float] = []
    for (params, input) in blocks {
        if let params { dsp.parameters.store(params) }
        output += runDSP(dsp, input: input, frames: frames)
    }
    return output
}

/// Largest jump between neighbouring samples. A step change in gain shows
/// up here as a spike far above what the signal itself can produce.
func maxDelta(_ samples: [Float]) -> Float {
    guard samples.count > 1 else { return 0 }
    var largest: Float = 0
    for index in 1..<samples.count {
        largest = max(largest, abs(samples[index] - samples[index - 1]))
    }
    return largest
}

do {
    let frames = 256

    // One continuous sine sampled across consecutive blocks — the phase has
    // to carry over, otherwise the test signal itself is discontinuous at
    // every block edge and swamps what is being measured.
    func toneBlock(_ index: Int) -> [Float] {
        (0..<frames).map { sinf(Float(index * frames + $0) * 0.01) }
    }
    let signalDelta = maxDelta(toneBlock(0) + toneBlock(1))

    var loud = ChannelDSPParameters.flat
    loud.volume = 1.0
    var quiet = ChannelDSPParameters.flat
    quiet.volume = 0.1

    let dsp = ChannelStripDSP(initial: loud)
    let output = renderBlocks(dsp, blocks: [
        (loud, toneBlock(0)), (quiet, toneBlock(1)), (loud, toneBlock(2)),
    ], frames: frames)

    // Ramping spreads the change over a whole block, so the worst
    // sample-to-sample jump stays in the same order as the signal's own
    // slope. A step change would put a near-full-scale edge right at the
    // block boundary.
    check("volume change stays continuous", maxDelta(output) < signalDelta * 3)

    var muted = ChannelDSPParameters.flat
    muted.isMuted = true
    let muteDSP = ChannelStripDSP(initial: loud)
    let muteOutput = renderBlocks(muteDSP, blocks: [
        (loud, toneBlock(0)), (muted, toneBlock(1)), (muted, toneBlock(2)),
    ], frames: frames)
    check("mute does not step to zero", maxDelta(muteOutput) < signalDelta * 3)
    // The ramp finishes within the block that requested the change, so the
    // block after it is fully silent.
    check("mute reaches silence", muteOutput.suffix(frames).allSatisfy { $0 == 0 })
}

runContractChecks()

print("")
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)

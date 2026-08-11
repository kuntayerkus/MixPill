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
    // The prime gate. A ring holding exactly one producer block is not yet
    // playable: handing it out leaves nothing behind, so the next late
    // block is a hole. Nothing is consumed while the gate is shut.
    let ring = RingBufferManager(capacityFrames: 1024, channelCount: 2)
    ring.write(from: makeBuffer(frames: 256) { _, _ in 0.5 })
    check("the target is a producer block plus a jitter margin",
          ring.targetFrames(consumerFrames: 256) == 512)
    let early = drain(ring, frames: 256)
    check("a half-filled cushion reads as silence", early[0].allSatisfy { $0 == 0 })
    check("a gated read consumes nothing", ring.availableFrames == 256)
    check("a gated read is not an underrun", ring.underruns == 0)
    check("a gated read is not a starvation", ring.starvations == 0)
    check("the ring is not primed yet", ring.isPrimed == false)
}

do {
    // Roundtrip: once the cushion is there, what goes in comes out in
    // order — and the cushion stays behind it.
    let ring = RingBufferManager(capacityFrames: 1024, channelCount: 2)
    ring.write(from: makeBuffer(frames: 256) { channel, frame in Float(frame) + Float(channel) * 1000 })
    ring.write(from: makeBuffer(frames: 256) { channel, frame in Float(frame) + 500 + Float(channel) * 1000 })
    let first = drain(ring, frames: 256)
    check("roundtrip preserves left channel", first[0] == (0..<256).map { Float($0) })
    check("roundtrip preserves right channel", first[1] == (0..<256).map { Float($0) + 1000 })
    check("the ring is primed once it has played", ring.isPrimed)
    check("a block of slack survives the read", ring.availableFrames == 256)
    let second = drain(ring, frames: 256)
    // Resampling reads one sample behind the play point and two ahead, so
    // the last two frames in the ring can never be handed out: they are the
    // interpolator's right-hand neighbours. Draining to the very bottom is
    // therefore a short read now, which is honest — a ring with two frames
    // left is a ring about to starve.
    check("the next read continues in order", second[0][0] > 490 && second[0][0] < 510)
    check("draining to the last two frames reads short", ring.underruns == 1)
}

do {
    // Underrun: primed, then handed less than a full block. Real frames
    // first, silence after — never stale data — and the gate re-arms so
    // the cushion is rebuilt in one silence instead of a hole per block.
    let ring = RingBufferManager(capacityFrames: 1024, channelCount: 2)
    for _ in 0..<5 {
        ring.write(from: makeBuffer(frames: 64) { _, _ in 0.5 })
    }
    _ = drain(ring, frames: 256)
    let out = drain(ring, frames: 256)
    check("underrun keeps real frames", Array(out[0][0..<64]) == [Float](repeating: 0.5, count: 64))
    check("underrun silence-pads remainder", Array(out[0][64..<256]) == [Float](repeating: 0, count: 192))
    check("a partial read counts one underrun", ring.underruns == 1)
    check("a partial read re-arms the gate", ring.isPrimed == false)
}

do {
    // Starvation: the failure the counters used to miss. An empty read on
    // a stream that *was* playing is a dropout and must be visible; the
    // same read on a channel that never played is an idle app.
    let ring = RingBufferManager(capacityFrames: 1024, channelCount: 2)
    for _ in 0..<8 { ring.write(from: makeBuffer(frames: 64) { _, _ in 0.25 }) }
    _ = drain(ring, frames: 256)          // primes and plays
    _ = drain(ring, frames: 256)          // takes all it can reach
    _ = drain(ring, frames: 256)          // now genuinely dry
    check("running out is reported", ring.underruns + ring.starvations >= 1)
    check("running out re-arms the gate", ring.isPrimed == false)

    let idle = RingBufferManager(capacityFrames: 1024, channelCount: 2)
    for _ in 0..<10 { _ = drain(idle, frames: 256) }
    check("an idle channel never counts a starvation", idle.starvations == 0)
    check("an idle channel never counts an underrun", idle.underruns == 0)
}

do {
    // Wrap-around: head crosses the end of storage mid-write. What must
    // survive is contiguity — a ramp written across the seam has to read
    // back as a ramp, with no repeated or skipped frame at the joint.
    //
    // Not from frame zero, though. The gate now opens *on* the target
    // rather than above it, so a ring holding more than the target when it
    // primes starts partway in; those frames were never played, and keeping
    // them would only mean starting with latency nobody asked for.
    let ring = RingBufferManager(capacityFrames: 1024, channelCount: 2)
    ring.write(from: makeBuffer(frames: 400) { _, _ in 1 })
    ring.write(from: makeBuffer(frames: 400) { _, _ in 1 })
    _ = drain(ring, frames: 400)
    _ = drain(ring, frames: 400)
    ring.write(from: makeBuffer(frames: 300) { _, frame in Float(frame) })
    ring.write(from: makeBuffer(frames: 300) { _, frame in Float(frame) + 300 })
    let out = drain(ring, frames: 300)
    let steps = zip(out[0], out[0].dropFirst()).map { $1 - $0 }
    check("a wrapped write reads back with no seam",
          steps.allSatisfy { $0 > 0.9 && $0 < 1.1 })
    check("a wrapped write reads back the newest frames",
          out[0][0] >= 0 && out[0][299] <= 599)
}

do {
    // The regression: a producer block larger than the whole ring. Before
    // the clamp this ran memcpy past the end of the storage allocation.
    let ring = RingBufferManager(capacityFrames: 512, channelCount: 2)
    let oversized = 4096
    ring.write(from: makeBuffer(frames: oversized) { _, frame in Float(frame) })
    check("oversized write does not exceed capacity", ring.availableFrames <= ring.capacity)
    check("the target never exceeds half the ring",
          ring.targetFrames(consumerFrames: 256) == ring.capacity / 2)
    // The newest frames are the ones kept: an oversized write drops from the
    // front, and the gate then starts one target behind the writer.
    let out = drain(ring, frames: 256)
    let steps = zip(out[0], out[0].dropFirst()).map { $1 - $0 }
    check("oversized write keeps the newest frames",
          out[0][0] > Float(oversized - ring.capacity) - 3
          && out[0][255] < Float(oversized))
    check("oversized write reads back with no seam",
          steps.allSatisfy { $0 > 0.9 && $0 < 1.1 })
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

do {
    // A rebuild re-learns the producer's block size rather than carrying
    // the old one forward — the capture block halves in low-latency mode,
    // and a stale cushion would keep charging for latency nobody asked for.
    let ring = RingBufferManager(capacityFrames: 4096, channelCount: 2)
    ring.write(from: makeBuffer(frames: 1024) { _, _ in 1 })
    check("the cushion follows the producer", ring.targetFrames(consumerFrames: 256) == 1536)
    ring.reset()
    check("a reset forgets the old producer block", ring.targetFrames(consumerFrames: 256) == 256)
    check("a reset closes the gate", ring.isPrimed == false)
}

// ── Occupancy control ─────────────────────────────────────────────────────
//
// The failure these lock down was measured rather than imagined: a stall
// left the ring pinned at 7168–7936 of 8192 with a target of 1280 — 160 ms
// of latency and a discarded block every few seconds, permanently, because
// nothing in the pipeline could ever give occupancy back.

/// Runs a producer and a consumer against one ring for `blocks` producer
/// periods, at a producer rate scaled by `rateRatio` (1.0 = perfectly
/// matched clocks). Feeds a phase-continuous sine so the output can be
/// inspected for splices.
@discardableResult
func pump(_ ring: RingBufferManager,
          producerFrames: Int,
          consumerFrames: Int,
          blocks: Int,
          rateRatio: Double = 1.0,
          phase: inout Double,
          onRead: ((_ output: [Float]) -> Void)? = nil) -> Int {
    let step = 2.0 * Double.pi * 1000.0 / 48000.0
    var credit = 0.0
    var reads = 0
    for _ in 0..<blocks {
        credit += Double(producerFrames) * rateRatio
        let toWrite = Int(credit)
        credit -= Double(toWrite)
        if toWrite > 0 {
            ring.write(from: makeBuffer(frames: toWrite) { _, frame in
                Float(sin(phase + Double(frame) * step))
            })
            phase += Double(toWrite) * step
        }
        for _ in 0..<(producerFrames / consumerFrames) {
            let out = drain(ring, frames: consumerFrames)
            onRead?(out[0])
            reads += 1
        }
    }
    return reads
}

do {
    // Matched clocks: the controller must sit still. A resync costs a
    // crossfade, so one that fires when nothing is wrong is its own bug.
    let ring = RingBufferManager(capacityFrames: 8192, channelCount: 2)
    var phase = 0.0
    pump(ring, producerFrames: 1024, consumerFrames: 256, blocks: 400, phase: &phase)
    check("matched clocks never resync", ring.resyncs == 0)
    check("matched clocks never starve", ring.starvations == 0)
    check("matched clocks never drop", ring.drops == 0)
    // One producer block of slack above the target is the sawtooth itself,
    // not accumulation: the producer delivers a whole block at once.
    check("matched clocks hold the target latency",
          ring.availableFrames <= ring.targetFrames(consumerFrames: 256) + 1024)
}

do {
    // The measured failure. A stall — the output IO cycle pausing while the
    // tap keeps writing — pins the ring at capacity. It must come back.
    let ring = RingBufferManager(capacityFrames: 8192, channelCount: 2)
    var phase = 0.0
    pump(ring, producerFrames: 1024, consumerFrames: 256, blocks: 8, phase: &phase)
    let target = ring.targetFrames(consumerFrames: 256)

    // 200 ms of producer with no consumer at all.
    for _ in 0..<10 {
        ring.write(from: makeBuffer(frames: 1024) { _, _ in 0.5 })
    }
    check("a stall does pin the ring at capacity", ring.availableFrames >= ring.capacity - 1024)

    // Long enough for the controller to reach a verdict: it wants several
    // observation windows in agreement before it spends a crossfade.
    pump(ring, producerFrames: 1024, consumerFrames: 256, blocks: 400, phase: &phase)
    check("a stall is corrected, not carried", ring.availableFrames <= target)
    check("correcting a stall is counted as a resync", ring.resyncs >= 1)
    check("correcting a stall does not silence the channel", ring.starvations == 0)
}

do {
    // Clock drift, both signs. Measured on the reference rig at +9.8 ppm;
    // these run four orders of magnitude faster so the test finishes, which
    // is the same effect compressed in time.
    let fast = RingBufferManager(capacityFrames: 8192, channelCount: 2)
    var fastPhase = 0.0
    pump(fast, producerFrames: 1024, consumerFrames: 256, blocks: 3000, rateRatio: 1.001, phase: &fastPhase)
    check("a fast producer never overflows into a discarded block", fast.drops == 0)
    // The whole point of steering the rate: drift is absorbed inside the
    // samples, so it costs no splice at all.
    check("a fast producer needs no splice", fast.resyncs == 0)
    check("a fast producer is answered by the rate loop",
          fast.rateCorrectionPPM > 800 && fast.rateCorrectionPPM < 1200)
    // The measured failure had the ring parked at 7168–7936 of 8192. The
    // claim worth making is that latency stays nowhere near that wall.
    check("a fast producer does not accumulate latency",
          fast.availableFrames < fast.capacity / 2)

    let slow = RingBufferManager(capacityFrames: 8192, channelCount: 2)
    var slowPhase = 0.0
    pump(slow, producerFrames: 1024, consumerFrames: 256, blocks: 3000, rateRatio: 0.999, phase: &slowPhase)
    check("a slow producer never starves the render callback", slow.starvations == 0)
    check("a slow producer never reads short", slow.underruns == 0)
    check("a slow producer needs no splice", slow.resyncs == 0)
    check("a slow producer is answered by the rate loop",
          slow.rateCorrectionPPM < -800 && slow.rateCorrectionPPM > -1200)
}

do {
    // Sustained load, which is a different failure from one stall: the
    // render thread is descheduled again and again, and the controller's
    // own evidence is counted in reads it is not being given. Measured on
    // hardware with every core spinning, the windowed path alone left ~20
    // discarded blocks a second; the ring has to ride these out on
    // capacity and correct on sight when it comes back.
    let ring = RingBufferManager(capacityFrames: 32768, channelCount: 2)
    var phase = 0.0
    pump(ring, producerFrames: 1024, consumerFrames: 256, blocks: 40, phase: &phase)

    for _ in 0..<40 {
        // 100 ms of producer with the consumer descheduled…
        for _ in 0..<5 {
            ring.write(from: makeBuffer(frames: 1024) { _, _ in 0.3 })
        }
        // …then a short burst of catching up before the next stall.
        pump(ring, producerFrames: 1024, consumerFrames: 256, blocks: 6, phase: &phase)
    }
    check("repeated stalls never discard a block", ring.drops == 0)
    check("repeated stalls never silence the channel", ring.starvations == 0)
    check("repeated stalls are corrected on sight",
          ring.availableFrames <= ring.targetFrames(consumerFrames: 256) + 4 * 1024)
}

do {
    // The crossfade has to be worth paying for: a resync that splices
    // instead of blending is the very click this replaces. A 1 kHz sine at
    // full scale steps by at most 0.131 per sample, so anything past twice
    // that is a discontinuity rather than the signal's own slope.
    let ring = RingBufferManager(capacityFrames: 8192, channelCount: 2)
    var phase = 0.0
    pump(ring, producerFrames: 1024, consumerFrames: 256, blocks: 8, phase: &phase)
    for _ in 0..<10 {
        ring.write(from: makeBuffer(frames: 1024) { _, frame in
            Float(sin(phase + Double(frame) * 2.0 * Double.pi * 1000.0 / 48000.0))
        })
        phase += 1024.0 * 2.0 * Double.pi * 1000.0 / 48000.0
    }

    var worstStep: Float = 0
    var previous: Float = 0
    var seen = false
    pump(ring, producerFrames: 1024, consumerFrames: 256, blocks: 400, phase: &phase) { output in
        for sample in output {
            if seen { worstStep = max(worstStep, abs(sample - previous)) }
            previous = sample
            seen = true
        }
    }
    check("the resync happened in this run", ring.resyncs >= 1)
    check("a resync crossfades rather than splices", worstStep < 0.262)
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

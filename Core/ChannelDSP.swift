import Foundation
import Accelerate

/// The five parametric EQ sections, stored inline.
///
/// Deliberately **not** an array. The render thread reads this block out of
/// an `RTParameterStore` on every callback, and a Swift array inside the
/// parameter struct means a retain/release pair per load, plus — when the
/// coefficients changed — a `flatMap` to hand vDSP a contiguous buffer.
/// That last one is a heap allocation inside a CoreAudio render callback,
/// which is exactly the kind of unbounded pause that turns into
/// `kAudioDeviceProcessorOverload` and an audible click.
///
/// A fixed-width SIMD lane group is plain old data: the whole parameter
/// block copies with a `memcpy`, and vDSP gets its pointer from the stack.
struct EQCoefficients: Sendable, Equatable {
    /// One section per band; the count never varies, because a flat band
    /// becomes a pass-through section rather than being dropped.
    static let sectionCount = 5
    /// vDSP order: [b0, b1, b2, a1, a2].
    static let coefficientsPerSection = 5
    static let floatCount = sectionCount * coefficientsPerSection   // 25

    /// 32 lanes for 25 values — the next SIMD width up. The slack is never
    /// read; `floatCount` bounds every access.
    private var storage = SIMD32<Float>()

    init() {}

    /// Builds a block from `sectionCount` rows of five coefficients.
    init?(sections: [[Float]]) {
        guard sections.count == Self.sectionCount else { return nil }
        var index = 0
        for section in sections {
            guard section.count == Self.coefficientsPerSection else { return nil }
            for coefficient in section {
                storage[index] = coefficient
                index += 1
            }
        }
    }

    subscript(index: Int) -> Float {
        get { storage[index] }
        set { storage[index] = newValue }
    }

    /// One section as an array. Off the render path only — this allocates.
    func section(_ index: Int) -> [Float] {
        let base = index * Self.coefficientsPerSection
        return (0..<Self.coefficientsPerSection).map { storage[base + $0] }
    }

    /// Hands vDSP a contiguous `Float` pointer without touching the heap.
    @inline(__always)
    func withUnsafeCoefficients<R>(_ body: (UnsafePointer<Float>) -> R) -> R {
        withUnsafePointer(to: storage) { pointer in
            pointer.withMemoryRebound(to: Float.self, capacity: Self.floatCount) { body($0) }
        }
    }

    /// The identity cascade: every section passes the signal through.
    static let passThrough: EQCoefficients = {
        var block = EQCoefficients()
        for section in 0..<sectionCount {
            block[section * coefficientsPerSection] = 1
        }
        return block
    }()

    /// `passThrough` as the `[Double]` vector `vDSP_biquad_CreateSetup` wants.
    static var passThroughDoubles: [Double] {
        (0..<floatCount).map { Double(passThrough[$0]) }
    }
}

/// Immutable DSP parameter snapshot for one channel strip. Written on the
/// control queue, observed on the render thread through an
/// `RTParameterStore`.
///
/// Every field is a trivial value, which is the point: `load()` on the
/// render thread is a register/stack copy with no reference counting and no
/// allocation. Every coefficient that depends on the sample rate is
/// precomputed at control time, so the render pass never touches a
/// transcendental function except the compressor's level metering.
struct ChannelDSPParameters: Sendable, Equatable {
    var volume: Float
    var isMuted: Bool
    var noiseGateThreshold: Float
    var compressorEnabled: Bool
    /// DAW Direct: every stage except final gain is bypassed.
    var processingBypassed: Bool
    /// Smoothed on the render thread toward this target (Smart Ducking).
    var duckingTarget: Float
    /// True when at least one EQ band is non-flat.
    var eqEnabled: Bool
    /// Five biquad sections, inline.
    var eqCoefficients: EQCoefficients
    /// Bumped only when `eqCoefficients` actually changes, so the render
    /// thread reloads the filter exactly when the filter is different —
    /// not every time somebody nudges a volume slider.
    var generation: UInt64

    static let flat = ChannelDSPParameters(
        volume: 1.0,
        isMuted: false,
        noiseGateThreshold: 0,
        compressorEnabled: false,
        processingBypassed: false,
        duckingTarget: 1.0,
        eqEnabled: false,
        eqCoefficients: EQCoefficients(),
        generation: 0
    )
}

/// Parametric peaking biquad design (RBJ Audio EQ Cookbook), bandwidth
/// expressed in octaves. Frequencies follow the MixPill bands:
/// 100 Hz, 400 Hz, 1 kHz, 4 kHz, 10 kHz.
enum BiquadDesigner {
    static let bandFrequencies: [Float] = [100.0, 400.0, 1000.0, 4000.0, 10000.0]
    private static let bandwidthOctaves: Float = 1.0

    /// Returns a full five-section block, or nil when every gain is flat
    /// (the caller then skips the EQ stage entirely).
    ///
    /// The section count is deliberately **constant**: a flat band becomes a
    /// pass-through section rather than being dropped. `vDSP_biquad`'s setup
    /// object is allocated for a fixed number of sections, so a varying count
    /// would make `vDSP_biquad_SetCoefficientsSingle` write past the setup
    /// and leave the delay state undersized.
    static func peakingCoefficients(gains: [Float], sampleRate: Double) -> EQCoefficients? {
        var anyNonFlat = false
        var block = EQCoefficients()

        for index in 0..<bandFrequencies.count {
            let base = index * EQCoefficients.coefficientsPerSection
            let gainDB = index < gains.count ? gains[index] : 0
            if abs(gainDB) < 0.01 {
                block[base] = 1      // b0 = 1, everything else already zero
                continue
            }
            anyNonFlat = true

            let frequency = bandFrequencies[index]
            let amplitude = pow(10.0, gainDB / 40.0)
            let w0 = 2.0 * Double.pi * Double(frequency) / sampleRate
            let sinW0 = sin(w0)
            let cosW0 = Float(cos(w0))

            // RBJ bandwidth form of alpha.
            let alpha = Float(sinW0 * sinh(log(2.0) / 2.0 * Double(bandwidthOctaves) * w0 / sinW0))

            let b0 = 1.0 + alpha * amplitude
            let b1 = -2.0 * cosW0
            let b2 = 1.0 - alpha * amplitude
            let a0 = 1.0 + alpha / amplitude
            let a1 = -2.0 * cosW0
            let a2 = 1.0 - alpha / amplitude

            block[base + 0] = b0 / a0
            block[base + 1] = b1 / a0
            block[base + 2] = b2 / a0
            block[base + 3] = a1 / a0
            block[base + 4] = a2 / a0
        }

        return anyNonFlat ? block : nil
    }
}

/// Render-side DSP state for one channel strip. All storage is allocated
/// up front; `process` performs no allocation, no locking, and no Obj-C
/// or Swift-runtime calls beyond plain arithmetic and vDSP.
final class ChannelStripDSP: @unchecked Sendable {
    /// Smart Ducking ramp length, matching the previous 0.4 s feel.
    private static let duckingRampSeconds = 0.4

    /// Compressor constants (mirror of the former 'cmp ' AU slots).
    private static let compressorThresholdDB: Float = -18.0
    private static let compressorRatio: Float = 3.0
    private static let compressorMakeupDB: Float = 2.0
    private static let compressorAttackSeconds: Float = 0.005
    private static let compressorReleaseSeconds: Float = 0.300

    /// Noise gate release hysteresis: the gate closes only when the level
    /// falls clearly below the open threshold, so hover-level signals do
    /// not chatter.
    private static let gateHysteresis: Float = 0.85

    /// `vDSP_biquad` reads and writes `Delay[2*s]` and `Delay[2*s+1]` for
    /// **s = 0 … S inclusive** — see the state save/restore loops in
    /// `vDSP.h`. That is `2*S + 2` floats, not `2*S`. Sizing it at `2*S`
    /// overran the buffer by eight bytes on every block of every EQ-enabled
    /// channel, from inside the render callback. It survived the
    /// guard-malloc checks because a 40-byte request lands inside a larger
    /// allocation bucket, so the overrun never reached a guard page.
    private static let delayCount = EQCoefficients.sectionCount * 2 + 2

    let parameters: RTParameterStore<ChannelDSPParameters>

    // MARK: Render-thread state

    private var appliedGeneration: UInt64 = 0
    /// Allocated once, for a fixed five sections, on the control thread.
    /// The render path only ever updates its coefficients in place.
    private let biquadSetup: vDSP_biquad_Setup?
    private var eqStateLeft: [Float]
    private var eqStateRight: [Float]

    private var gateOpen = true
    private var compressorGainReductionDB: Float = 0
    private var duckingMultiplier: Float = 1.0
    /// The gain actually applied to the last sample of the previous block.
    /// Held so the next block can start from it rather than jumping.
    private var appliedGain: Float = 1.0
    private var hasAppliedGain = false

    init(initial: ChannelDSPParameters) {
        parameters = RTParameterStore(initial: initial)
        eqStateLeft = [Float](repeating: 0, count: Self.delayCount)
        eqStateRight = [Float](repeating: 0, count: Self.delayCount)
        biquadSetup = vDSP_biquad_CreateSetup(
            EQCoefficients.passThroughDoubles,
            vDSP_Length(EQCoefficients.sectionCount)
        )
        if biquadSetup == nil {
            MixPillCoreLog.log("ChannelStripDSP: biquad setup allocation failed; EQ will be bypassed")
        }
    }

    deinit {
        if let biquadSetup {
            vDSP_biquad_DestroySetup(biquadSetup)
        }
    }

    /// Reinitializes transient state after an engine rebuild (sample rate
    /// or graph changes make old filter state meaningless). Control queue.
    func resetTransientState() {
        gateOpen = true
        compressorGainReductionDB = 0
        duckingMultiplier = parameters.load().duckingTarget
        hasAppliedGain = false
        for index in 0..<Self.delayCount {
            eqStateLeft[index] = 0
            eqStateRight[index] = 0
        }
    }

    // MARK: Render path

    /// Processes one stereo block in place. `left`/`right` point at
    /// `frameCount` frames each.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int, sampleRate: Double) {
        guard frameCount > 0 else { return }
        let frames = vDSP_Length(frameCount)
        let params = parameters.load()

        // Final gain is applied even in bypass mode so volume, mute and
        // ducking stay live for DAW Direct channels.
        let duckingRamp = min(1.0, Float(frameCount) / Float(Self.duckingRampSeconds * sampleRate))
        duckingMultiplier += (params.duckingTarget - duckingMultiplier) * duckingRamp
        let gain = params.isMuted ? 0.0 : params.volume * duckingMultiplier

        if params.processingBypassed {
            applyGain(gain, left: left, right: right, frames: frames)
            return
        }

        // 1. Noise gate (block level, with hysteresis).
        if params.noiseGateThreshold > 0 {
            var rmsLeft: Float = 0
            var rmsRight: Float = 0
            vDSP_rmsqv(left, 1, &rmsLeft, frames)
            vDSP_rmsqv(right, 1, &rmsRight, frames)
            let level = max(rmsLeft, rmsRight)

            if gateOpen {
                if level < params.noiseGateThreshold * Self.gateHysteresis {
                    gateOpen = false
                }
            } else if level >= params.noiseGateThreshold {
                gateOpen = true
            }

            guard gateOpen else {
                vDSP_vclr(left, 1, frames)
                vDSP_vclr(right, 1, frames)
                return
            }
        }

        // 2. Five-band parametric EQ (cascaded biquads).
        if params.eqEnabled {
            runEQ(params, left: left, right: right, frameCount: frameCount)
        }

        // 3. Feed-forward compressor (Night Mode), bypassed by default.
        if params.compressorEnabled {
            runCompressor(left: left, right: right, frameCount: frameCount, sampleRate: sampleRate)
        }

        // 4. Channel gain.
        applyGain(gain, left: left, right: right, frames: frames)
    }

    // MARK: Stages

    /// Loads new coefficients only when the generation moved, and even then
    /// without allocating: the block is inline storage and vDSP writes into
    /// a setup that was created once, for a fixed section count.
    private func runEQ(_ params: ChannelDSPParameters,
                       left: UnsafeMutablePointer<Float>,
                       right: UnsafeMutablePointer<Float>,
                       frameCount: Int) {
        guard let setup = biquadSetup else { return }

        if params.generation != appliedGeneration {
            params.eqCoefficients.withUnsafeCoefficients { coefficients in
                vDSP_biquad_SetCoefficientsSingle(
                    setup, coefficients, 0, vDSP_Length(EQCoefficients.sectionCount)
                )
            }
            appliedGeneration = params.generation
        }

        let frames = vDSP_Length(frameCount)
        eqStateLeft.withUnsafeMutableBufferPointer { delayLeft in
            vDSP_biquad(setup, delayLeft.baseAddress!, left, 1, left, 1, frames)
        }
        eqStateRight.withUnsafeMutableBufferPointer { delayRight in
            vDSP_biquad(setup, delayRight.baseAddress!, right, 1, right, 1, frames)
        }
    }

    private func runCompressor(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int, sampleRate: Double) {
        let frames = vDSP_Length(frameCount)
        var rmsLeft: Float = 0
        var rmsRight: Float = 0
        vDSP_rmsqv(left, 1, &rmsLeft, frames)
        vDSP_rmsqv(right, 1, &rmsRight, frames)

        let level = max(max(rmsLeft, rmsRight), 1e-6)
        let levelDB = 20.0 * log10(level)

        var targetReductionDB: Float = 0
        if levelDB > Self.compressorThresholdDB {
            let overDB = levelDB - Self.compressorThresholdDB
            targetReductionDB = overDB * (1.0 - 1.0 / Self.compressorRatio)
        }

        let blockDuration = Float(Double(frameCount) / sampleRate)
        let tau = targetReductionDB > compressorGainReductionDB
            ? Self.compressorAttackSeconds
            : Self.compressorReleaseSeconds
        let coefficient = min(1.0, blockDuration / tau)
        compressorGainReductionDB += (targetReductionDB - compressorGainReductionDB) * coefficient

        var linearGain = pow(10.0, (Self.compressorMakeupDB - compressorGainReductionDB) / 20.0)
        vDSP_vsmul(left, 1, &linearGain, left, 1, frames)
        vDSP_vsmul(right, 1, &linearGain, right, 1, frames)
    }

    /// Applies the channel gain, ramping across the block rather than
    /// switching at its edge.
    ///
    /// A constant multiplier per block means every change of volume, mute
    /// or ducking is a step discontinuity in the waveform at a block
    /// boundary — the classic "zipper" click. Dragging a slider produced
    /// one every 5.3 ms, and muting produced a full-scale jump to zero.
    /// Interpolating from the previous block's final gain to this block's
    /// target removes the discontinuity: the change still lands within one
    /// I/O block, so it feels instant, but the waveform stays continuous.
    private func applyGain(_ target: Float, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: vDSP_Length) {
        // The first block after a rebuild has no previous value to ramp
        // from; starting at the target avoids fading up out of nowhere.
        if !hasAppliedGain {
            appliedGain = target
            hasAppliedGain = true
        }

        defer { appliedGain = target }

        if appliedGain == target {
            guard target != 1.0 else { return }
            var gain = target
            vDSP_vsmul(left, 1, &gain, left, 1, frames)
            vDSP_vsmul(right, 1, &gain, right, 1, frames)
            return
        }

        var step = (target - appliedGain) / Float(frames)

        // `vDSP_vrampmul` advances the start value in place, so each channel
        // needs its own copy to begin from the same point.
        var leftStart = appliedGain
        vDSP_vrampmul(left, 1, &leftStart, &step, left, 1, frames)

        var rightStart = appliedGain
        vDSP_vrampmul(right, 1, &rightStart, &step, right, 1, frames)
    }
}

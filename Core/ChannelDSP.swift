import Foundation
import Accelerate

/// Immutable DSP parameter snapshot for one channel strip. Written on the
/// control queue, observed on the render thread through an
/// `RTParameterStore`. Every coefficient that depends on the sample rate
/// is precomputed here at control time, so the render pass never touches
/// a transcendental function except the compressor's level metering.
struct ChannelDSPParameters: Sendable {
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
    /// 5 biquads × 5 coefficients in vDSP order [b0, b1, b2, a1, a2].
    var eqCoefficients: [[Float]]
    /// Bumped on every write so the render thread can detect new
    /// coefficients without comparing the whole block.
    var generation: UInt64

    static let flat = ChannelDSPParameters(
        volume: 1.0,
        isMuted: false,
        noiseGateThreshold: 0,
        compressorEnabled: false,
        processingBypassed: false,
        duckingTarget: 1.0,
        eqEnabled: false,
        eqCoefficients: [],
        generation: 0
    )
}

/// Parametric peaking biquad design (RBJ Audio EQ Cookbook), bandwidth
/// expressed in octaves. Frequencies follow the MixPill bands:
/// 100 Hz, 400 Hz, 1 kHz, 4 kHz, 10 kHz.
enum BiquadDesigner {
    static let bandFrequencies: [Float] = [100.0, 400.0, 1000.0, 4000.0, 10000.0]
    private static let bandwidthOctaves: Float = 1.0

    /// Identity section: passes the signal through untouched.
    private static let passThrough: [Float] = [1, 0, 0, 0, 0]

    /// Returns exactly `bandFrequencies.count` biquad coefficient rows in
    /// vDSP order, or nil when every gain is flat (the caller then skips
    /// the EQ stage entirely).
    ///
    /// The row count is deliberately **constant**: a flat band becomes a
    /// pass-through section rather than being dropped. `vDSP_biquad`'s
    /// setup object is allocated for a fixed number of sections, so a
    /// varying count would make `vDSP_biquad_SetCoefficientsSingle` write
    /// past the setup and the delay state undersized.
    static func peakingCoefficients(gains: [Float], sampleRate: Double) -> [[Float]]? {
        var anyNonFlat = false
        var rows: [[Float]] = []

        for index in 0..<bandFrequencies.count {
            let gainDB = index < gains.count ? gains[index] : 0
            if abs(gainDB) < 0.01 {
                rows.append(passThrough)
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

            rows.append([b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0])
        }

        return anyNonFlat ? rows : nil
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

    let parameters: RTParameterStore<ChannelDSPParameters>

    // MARK: Render-thread state

    private var appliedGeneration: UInt64 = 0
    private var biquadSetup: vDSP_biquad_Setup?
    /// Number of sections `biquadSetup` was allocated for. A setup can only
    /// ever be updated with exactly this many sections.
    private var setupSectionCount = 0
    private var eqStateLeft: [Float] = []
    private var eqStateRight: [Float] = []

    private var gateOpen = true
    private var compressorGainReductionDB: Float = 0
    private var duckingMultiplier: Float = 1.0
    /// The gain actually applied to the last sample of the previous block.
    /// Held so the next block can start from it rather than jumping.
    private var appliedGain: Float = 1.0
    private var hasAppliedGain = false

    init(initial: ChannelDSPParameters) {
        parameters = RTParameterStore(initial: initial)
    }

    deinit {
        if let setup = biquadSetup {
            vDSP_biquad_DestroySetup(setup)
        }
    }

    /// Reinitializes transient state after an engine rebuild (sample rate
    /// or graph changes make old filter state meaningless). Control queue.
    func resetTransientState() {
        gateOpen = true
        compressorGainReductionDB = 0
        duckingMultiplier = parameters.load().duckingTarget
        hasAppliedGain = false
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
        if params.eqEnabled, let coefficients = params.eqCoefficients.isEmpty ? nil : params.eqCoefficients {
            if params.generation != appliedGeneration {
                prepareEQSetup(coefficients)
                appliedGeneration = params.generation
            }
            runEQ(left: left, right: right, frameCount: frameCount, bands: coefficients.count)
        }

        // 3. Feed-forward compressor (Night Mode), bypassed by default.
        if params.compressorEnabled {
            runCompressor(left: left, right: right, frameCount: frameCount, sampleRate: sampleRate)
        }

        // 4. Channel gain.
        applyGain(gain, left: left, right: right, frames: frames)
    }

    // MARK: Stages

    private func prepareEQSetup(_ coefficients: [[Float]]) {
        let count = coefficients.count
        guard count > 0 else { return }

        let flatCoeffs = coefficients.flatMap { $0 }
        guard flatCoeffs.count == count * 5 else { return }

        if eqStateLeft.count != count * 2 {
            eqStateLeft = [Float](repeating: 0, count: count * 2)
            eqStateRight = [Float](repeating: 0, count: count * 2)
        }

        // A setup is bound to its section count for life; if the count ever
        // changes, the old setup has to go rather than be written past.
        if let setup = biquadSetup, setupSectionCount != count {
            vDSP_biquad_DestroySetup(setup)
            biquadSetup = nil
            setupSectionCount = 0
        }

        if biquadSetup == nil {
            let doubleCoeffs = flatCoeffs.map { Double($0) }
            biquadSetup = vDSP_biquad_CreateSetup(doubleCoeffs, vDSP_Length(count))
            setupSectionCount = biquadSetup == nil ? 0 : count
        } else if let setup = biquadSetup {
            vDSP_biquad_SetCoefficientsSingle(setup, flatCoeffs, 0, vDSP_Length(count))
        }
    }

    private func runEQ(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int, bands: Int) {
        guard let setup = biquadSetup, eqStateLeft.count == bands * 2 else { return }
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

import Foundation
@preconcurrency import AVFoundation

/// Explicit sample-rate/format conversion pipeline between capture and
/// the mixer.
///
/// Capture formats can change under our feet: AirPods flipping to 16 kHz
/// SCO mono, hi-res interfaces at 96 kHz or 192 kHz, channel-count flips.
/// Instead of rebuilding playback on every change — the classic source of
/// sample-rate-mismatch crashes — every incoming buffer is converted into
/// one canonical Float32 stereo format, and the whole playback side speaks
/// that format once and forever.
///
/// The canonical rate is **dynamic**: it automatically matches the active
/// clock of the connected audio interface (44.1 / 48 / 88.2 / 96 / 176.4 /
/// 192 kHz), so hi-res sessions stay native-quality. When the clock
/// changes, the resilience engine rebuilds the mixer and the EQ
/// coefficients are recomputed for the new rate.
public final class AudioResamplerService: @unchecked Sendable {
    public static let shared = AudioResamplerService()

    /// The single format the mixer speaks. Float32 stereo at the
    /// interface's active clock rate (48 kHz until a clock is detected).
    public static var canonicalFormat: AVAudioFormat {
        shared.currentCanonicalFormat
    }

    public var currentCanonicalFormat: AVAudioFormat {
        lock.withLock { canonical }
    }

    private struct ConverterKey: Hashable {
        let sampleRate: Double
        let channelCount: UInt32
        let interleaved: Bool
    }

    private let lock = UnfairLock()
    private var canonical: AVAudioFormat
    private var converters: [ConverterKey: AVAudioConverter] = [:]

    private init() {
        canonical = Self.makeFormat(CoreAudioFormat.baseSampleRate)
    }

    private static func makeFormat(_ sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: CoreAudioFormat.channelCount,
            interleaved: false
        )!
    }

    /// Snaps the canonical processing rate to the connected interface's
    /// clock. Returns true when the rate actually changed (the caller then
    /// rebuilds the mixer graph).
    @discardableResult
    public func matchHardwareSampleRate(_ rate: Double) -> Bool {
        let target = CoreAudioFormat.supportedHardwareRates.min(by: { abs($0 - rate) < abs($1 - rate) })
            ?? CoreAudioFormat.baseSampleRate

        return lock.withLock {
            guard canonical.sampleRate != target else { return false }

            canonical = Self.makeFormat(target)
            converters.removeAll()
            MixPillCoreLog.log("AudioResamplerService: canonical processing rate matched hardware clock at \(Int(target)) Hz")
            return true
        }
    }

    public var activeConverterCount: Int {
        lock.withLock { converters.count }
    }

    /// Converts any incoming Float32 PCM buffer into the canonical format.
    /// Buffers already in canonical format pass through without copying.
    /// Returns nil only if a converter cannot be built or errors; callers
    /// drop the buffer and move on.
    ///
    /// Called exclusively from the capture producer path; converters are
    /// not safe for concurrent use, and this object serializes access to
    /// the cache itself.
    public func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = input.format
        guard source.sampleRate > 0, input.frameLength > 0 else { return nil }

        let target = currentCanonicalFormat

        if source.sampleRate == target.sampleRate
            && source.channelCount == target.channelCount
            && !source.isInterleaved {
            return input
        }

        let key = ConverterKey(
            sampleRate: source.sampleRate,
            channelCount: source.channelCount,
            interleaved: source.isInterleaved
        )

        let converter = lock.withLock {
            var converter = converters[key]
            if converter == nil {
                converter = AVAudioConverter(from: source, to: target)
                if let converter {
                    converters[key] = converter
                }
            }
            return converter
        }

        guard let converter else { return nil }

        let ratio = target.sampleRate / source.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: estimatedFrames) else {
            return nil
        }

        // `convert(to:error:withInputFrom:)` runs its block synchronously on
        // this thread before returning, so the shared state below is not
        // actually concurrent. Swift 6 cannot see that through the
        // `@Sendable` annotation on the block, so the flag lives in a box it
        // can reason about instead of being a captured `var`.
        final class InputState: @unchecked Sendable { var supplied = false }
        let state = InputState()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [state] _, outStatus in
            if state.supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.supplied = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error {
            if let conversionError {
                MixPillCoreLog.log("AudioResamplerService: conversion failed: \(conversionError)")
            }
            return nil
        }

        return output
    }

    /// Cached converters can reference dead formats after a coreaudiod
    /// restart; recovery paths call this to start clean.
    public func reset() {
        lock.withLockVoid { converters.removeAll() }
    }
}

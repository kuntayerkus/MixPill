import Foundation
@preconcurrency import AVFoundation

/// The one canonical audio format the whole engine speaks.
///
/// Capture formats can change under our feet: AirPods flipping to 16 kHz
/// SCO mono, hi-res interfaces at 96 kHz or 192 kHz, channel-count flips.
/// Rather than rebuild playback on every change — the classic source of
/// sample-rate-mismatch crashes — capture, mixing and playback all agree on
/// one Float32 stereo format, and AUHAL converts to whatever the device
/// actually wants on its own.
///
/// The canonical rate is **dynamic**: it matches the active clock of the
/// connected interface (44.1 / 48 / 88.2 / 96 / 176.4 / 192 kHz), so hi-res
/// sessions stay native-quality. When the clock changes, the resilience
/// engine rebuilds the mixer and the EQ coefficients are recomputed for the
/// new rate.
///
/// This used to also own an `AVAudioConverter` cache and a `convert(_:)`
/// entry point, from the era when capture arrived as `AVAudioPCMBuffer`s in
/// whatever format the source produced. The process-tap path writes planar
/// floats straight into the ring, so nothing had called it in a long time —
/// and because the cache was therefore always empty, the Diagnostics panel
/// reported "Resampler: Idle (passthrough)" unconditionally, which is a row
/// that can only ever say one thing.
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

    private let lock = UnfairLock()
    private var canonical: AVAudioFormat

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
            MixPillCoreLog.log("AudioResamplerService: canonical processing rate matched hardware clock at \(Int(target)) Hz")
            return true
        }
    }
}

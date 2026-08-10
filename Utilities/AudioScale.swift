import Foundation

/// The one place that decides how linear amplitude becomes something a
/// person can read or steer.
///
/// Hearing is logarithmic and every one of these controls was linear, which
/// made both of them lie in the same direction:
///
/// - The level meter drew `amplitude × width`. Music mastered to −18 dBFS
///   RMS is 0.126 linear, so it filled an eighth of the bar, and the yellow
///   and red zones at 0.75 and 0.92 were unreachable in normal listening.
/// - The volume fader drove the gain directly. "50%" is −6 dB, which is
///   nowhere near half as loud, and the entire usable range was crammed
///   into the top fifth of the travel.
///
/// Shared by the interface and the engine, so the numbers a user sees and
/// the numbers the DSP applies come from the same definitions.
public enum AudioScale {

    // MARK: - Decibels

    /// Below this, treat a signal as silence rather than a very small
    /// number: `log10(0)` is not a useful readout.
    public static let silenceFloor: Float = 1e-5

    public static func decibels(fromAmplitude amplitude: Float) -> Float {
        20 * log10(max(abs(amplitude), silenceFloor))
    }

    public static func amplitude(fromDecibels decibels: Float) -> Float {
        pow(10, decibels / 20)
    }

    // MARK: - Metering

    /// Bottom of the meter scale. −60 dBFS puts a quiet room's noise floor
    /// at the left edge and normal programme material two thirds along.
    public static let meterFloorDB: Float = -60

    /// Linear amplitude → 0…1 position on the meter's dBFS scale.
    public static func meterPosition(forAmplitude amplitude: Float) -> Float {
        guard amplitude > silenceFloor else { return 0 }
        let dB = decibels(fromAmplitude: amplitude)
        return min(1, max(0, (dB - meterFloorDB) / -meterFloorDB))
    }

    /// Meter position of a given dBFS mark, for drawing the colour stops
    /// and scale ticks at the levels they actually represent.
    public static func meterPosition(forDecibels decibels: Float) -> Float {
        min(1, max(0, (decibels - meterFloorDB) / -meterFloorDB))
    }

    /// Peaks at or above this count as clipping.
    public static let clipThresholdDB: Float = -0.1

    // MARK: - Faders

    /// Where unity sits on a channel fader's travel. The remaining fifth is
    /// boost, which is what makes a quietly mastered podcast or a
    /// too-soft conference call usable rather than merely quieter.
    public static let unityPosition: Float = 0.8
    /// Bottom of the fader's dB range; position 0 is true silence, not this.
    public static let faderFloorDB: Float = -48
    /// Ceiling above unity, in dB.
    public static let faderBoostDB: Float = 6

    /// Highest gain a channel fader can ask for.
    public static var maximumChannelGain: Float { amplitude(fromDecibels: faderBoostDB) }

    /// Fader travel (0…1) → linear gain.
    ///
    /// Linear in dB either side of unity, so equal movements of the knob
    /// are equal changes in loudness — which is the property a linear
    /// amplitude fader lacks.
    public static func gain(forPosition position: Float, allowBoost: Bool = true) -> Float {
        let clamped = min(1, max(0, position))
        guard clamped > 0 else { return 0 }

        let unity = allowBoost ? unityPosition : 1
        if clamped <= unity {
            let dB = faderFloorDB * (1 - clamped / unity)
            return amplitude(fromDecibels: dB)
        }
        let overshoot = (clamped - unity) / (1 - unity)
        return amplitude(fromDecibels: overshoot * faderBoostDB)
    }

    /// Linear gain → fader travel. The exact inverse of `gain(forPosition:)`.
    public static func position(forGain gain: Float, allowBoost: Bool = true) -> Float {
        guard gain > 0 else { return 0 }
        let unity = allowBoost ? unityPosition : 1
        let dB = decibels(fromAmplitude: gain)

        if dB <= 0 {
            let travel = 1 - dB / faderFloorDB
            return min(unity, max(0, travel * unity))
        }
        let overshoot = min(1, dB / faderBoostDB)
        return min(1, unity + overshoot * (1 - unity))
    }

    /// A fader's value as a person reads it: "0.0 dB", "−12.5 dB", "−∞".
    public static func faderLabel(forGain gain: Float) -> String {
        guard gain > 0 else { return "−∞" }
        let dB = decibels(fromAmplitude: gain)
        if dB <= faderFloorDB { return "−∞" }
        // A leading "+" marks boost as deliberate rather than incidental.
        let sign = dB > 0.05 ? "+" : ""
        return String(format: "\(sign)%.1f dB", dB)
    }

    /// Percentage of unity, for spoken accessibility values where "decibel"
    /// is not the more useful word.
    public static func percentOfUnity(forGain gain: Float) -> Int {
        Int((gain * 100).rounded())
    }

    // MARK: - Output limiting

    /// Ceiling the summed mix is held below, in linear amplitude.
    ///
    /// Just under full scale: MixPill adds channels together, and nothing
    /// downstream stops three apps at −3 dBFS from summing past 1.0 and
    /// being hard-clipped by CoreAudio.
    public static let limiterCeiling: Float = 0.99
    /// Per-block smoothing for the limiter's gain, attacking fast enough to
    /// catch a transient and releasing slowly enough not to pump.
    public static let limiterAttackCoefficient: Float = 0.6
    public static let limiterReleaseCoefficient: Float = 0.02
}

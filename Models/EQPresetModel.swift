import Foundation

/// The classic one-tap EQ profiles shown in the per-app equalizer popover.
/// Gains apply to the 100 Hz / 400 Hz / 1 kHz / 4 kHz / 10 kHz parametric
/// bands; the MixPillCore service turns them into biquad coefficients.
public enum EQPreset: String, CaseIterable, Identifiable, Sendable {
    case flat = "Flat"
    case bassBoost = "Bass Boost"
    case vocalClarity = "Vocal Clarity"
    case podcastClean = "Podcast Clean"

    public var id: String { self.rawValue }

    public var gains: [Float] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0]
        case .bassBoost: return [6.0, 4.0, 0, -2.0, -2.0]
        case .vocalClarity: return [-2.0, -1.0, 3.0, 4.0, 2.0]
        case .podcastClean: return [-4.0, -2.0, 2.0, 5.0, 1.0]
        }
    }

    public static func preset(matching gains: [Float]) -> EQPreset? {
        allCases.first { $0.gains == gains }
    }
}

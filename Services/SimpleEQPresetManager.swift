import Foundation
import Observation

/// Three one-click listening profiles for users who do not want to touch
/// EQ sliders. Each preset is a single button in the per-app EQ popover.
public enum SimpleEQPreset: String, CaseIterable, Identifiable, Sendable {
    case vocalClarity = "Vocal Clarity"
    case bassBoost = "Bass Boost"
    case nightMode = "Night Mode"

    public var id: String { rawValue }

    /// 5-band gains for the 100 Hz / 400 Hz / 1 kHz / 4 kHz / 10 kHz bands.
    public var gains: [Float] {
        switch self {
        case .vocalClarity:
            // Lift the speech band (1-4 kHz), ease off the lows.
            return [-1.0, 0.0, 3.5, 4.5, 1.5]
        case .bassBoost:
            // Lift the low end (100-250 Hz) without muddying the mids.
            return [6.0, 2.5, 0.0, -1.0, -1.0]
        case .nightMode:
            // Flat EQ; the dynamic range compressor does the work.
            return [0.0, 0.0, 0.0, 0.0, 0.0]
        }
    }

    public var symbolName: String {
        switch self {
        case .vocalClarity: return "person.wave.2"
        case .bassBoost: return "hifispeaker.fill"
        case .nightMode: return "moon.stars.fill"
        }
    }

    public var summary: String {
        switch self {
        case .vocalClarity: return "Enhances speech frequencies for meetings and podcasts"
        case .bassBoost: return "Enhances the low end for music"
        case .nightMode: return "Softens sudden loud noises for late-night listening"
        }
    }
}

/// Applies the one-click presets through the channel config store, which
/// persists them and forwards them to the MixPillCore service.
@MainActor
@Observable
public final class SimpleEQPresetManager {
    public static let shared = SimpleEQPresetManager()

    private init() {}

    public func apply(_ preset: SimpleEQPreset, forBundleID bundleID: String) {
        let store = ChannelConfigStore.shared
        store.setEQGains(preset.gains, for: bundleID)
        store.setNightMode(enabled: preset == .nightMode, for: bundleID)
    }

    /// Clears back to flat EQ with the compressor bypassed.
    public func clear(forBundleID bundleID: String) {
        let store = ChannelConfigStore.shared
        store.setEQGains(ChannelConfigStore.flatEQGains, for: bundleID)
        store.setNightMode(enabled: false, for: bundleID)
    }

    public func activePreset(forBundleID bundleID: String) -> SimpleEQPreset? {
        let store = ChannelConfigStore.shared
        if store.isNightMode(for: bundleID) {
            return .nightMode
        }
        let gains = store.eqGains(for: bundleID)
        return SimpleEQPreset.allCases.first { $0 != .nightMode && $0.gains == gains }
    }
}

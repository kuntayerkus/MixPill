import Foundation
import CoreGraphics
import SwiftUI

public struct Constants {
    // MARK: - UI Dimensions (HIG: Control Center spacing)
    public struct UI {
        public static let popoverWidth: CGFloat = 320
        public static let popoverHeight: CGFloat = 450
        public static let appRowHeight: CGFloat = 60
        public static let iconSize: CGFloat = 32
        public static let cornerRadius: CGFloat = 12

        // Standard macOS Control Center metrics
        public static let edgePadding: CGFloat = 12
        public static let interElementSpacing: CGFloat = 8
        public static let controlHeight: CGFloat = 28
        public static let headerFontSize: CGFloat = 11
        public static let hoverOpacity: CGFloat = 0.06
        public static let cardOpacity: CGFloat = 0.03
    }

    // MARK: - Motion (Apple signature spring physics)
    public struct Motion {
        public static let spring: Animation = .spring(response: 0.28, dampingFraction: 0.75)
    }

    // MARK: - Audio Defaults
    // All runtime audio constants (rates, block sizes, ducking curve) live
    // in MixPillCore — see Shared/CoreIdentifiers.swift and
    // Core/LowLatencyMixerEngine.swift. The UI only keeps display defaults.
    public struct Audio {
        public static let defaultVolume: Float = 1.0
        public static let defaultMuted: Bool = false
    }

    // MARK: - UserDefaults Keys
    public struct StorageKeys {
        public static let presets = "MixPill.Presets"
        public static let masterVolume = "MixPill.MasterVolume"
        public static let appVolumes = "MixPill.AppVolumes"
        public static let appMutes = "MixPill.AppMutes"
        public static let eqGains = "MixPill.EQGains"
        public static let noiseGates = "MixPill.NoiseGates"
        public static let routing = "MixPill.Routing"
        public static let automationRules = "MixPill.AutomationRules"
        public static let hasCompletedOnboarding = "hasCompletedOnboarding"
        public static let hotkeysEnabled = "MixPill.HotkeysEnabled"
        public static let lowLatencyMode = "MixPill.LowLatencyMode"
        public static let duckingEnabled = "MixPill.DuckingEnabled"
        public static let echoFreeFallbackDevice = "MixPill.EchoFreeFallbackDevice"
        public static let nightModes = "MixPill.NightModes"
        public static let focusShieldEnabled = "MixPill.FocusShieldEnabled"
        public static let dawDirectModes = "MixPill.DawDirectModes"
    }
}

import Foundation
import CoreGraphics
import SwiftUI
import AppKit

public struct Constants {
    // MARK: - UI Dimensions (HIG: Control Center spacing)
    public struct UI {
        public static let popoverWidth: CGFloat = 320
        public static let iconSize: CGFloat = 32
        public static let cornerRadius: CGFloat = 12

        // Standard macOS Control Center metrics
        public static let edgePadding: CGFloat = 12
        public static let interElementSpacing: CGFloat = 8
        public static let controlHeight: CGFloat = 28
        public static let headerFontSize: CGFloat = 11
        public static let hoverOpacity: CGFloat = 0.06
        public static let cardOpacity: CGFloat = 0.03

        /// Limiter reduction worth telling the user about, in dB. Below
        /// this the limiter is only breathing on a transient, and a badge
        /// blinking on every kick drum is noise, not information.
        public static let limiterVisibleDB: Float = 0.5
    }

    // MARK: - Motion (Apple signature spring physics)
    public struct Motion {
        /// The house spring — unless the user has asked the system for less
        /// movement, in which case it collapses to an instant change.
        ///
        /// Computed rather than stored so every existing call site honours
        /// Reduce Motion without being touched. `NSWorkspace` exposes the
        /// setting outside SwiftUI, so this works from view modifiers,
        /// `withAnimation` blocks and AppKit code alike.
        public static var spring: Animation {
            reduceMotion ? .linear(duration: 0) : .spring(response: 0.28, dampingFraction: 0.75)
        }

        public static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
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
        public static let masterMuted = "MixPill.MasterMuted"
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
        public static let nightModes = "MixPill.NightModes"
        public static let focusShieldEnabled = "MixPill.FocusShieldEnabled"
        public static let dawDirectModes = "MixPill.DawDirectModes"
    }
}

import Foundation
import Observation
import ApplicationServices
import AppKit

/// Tracks the one permission MixPill can actually need: **Accessibility**,
/// and only if the user turns on global hotkeys and quick gestures.
///
/// Mixing itself needs no permission at all. CoreAudio process taps of
/// specific processes are granted to a signed app without a TCC prompt,
/// which is verifiable in the engine log: taps are created and audio flows
/// with nothing granted. An earlier version of this class gated the whole
/// interface on `AVCaptureDevice.authorizationStatus(for: .audio)` — the
/// microphone grant — and so showed a permission wall in front of a mixer
/// that was already working, while sending people to a System Settings
/// pane MixPill was not even listed in.
///
/// The lesson is baked into the architecture now: capture health is
/// *observed* by the core and reported over XPC
/// (`captureAvailabilityChanged`), never inferred from a TCC status.
@MainActor
@Observable
public final class PermissionManager {
    /// Whether this process is trusted for Accessibility. Required only by
    /// `GlobalHotkeyManager` and `QuickGestureManager`.
    public var hasAccessibilityPermission: Bool = false

    public init() {
        checkPermissions()
    }

    public func checkPermissions() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    /// Opens System Settings › Privacy & Security › Accessibility.
    public func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

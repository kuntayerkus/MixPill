import Cocoa
import Foundation
import Observation

/// Global hotkeys (requires Accessibility permission):
/// - Command + Option + M: mute/unmute the frontmost app
///
/// The Option + Scroll volume gesture lives in `QuickGestureManager`; both
/// share the same user preference and Accessibility grant.
///
/// Permission handling is lazy by design: nothing is requested at launch.
/// The Accessibility prompt fires only from the "Enable Global Hotkeys"
/// toggle in Settings, and a previously-granted preference is restored
/// silently on subsequent launches.
@MainActor
@Observable
public final class GlobalHotkeyManager {
    public static let shared = GlobalHotkeyManager()

    public private(set) var isEnabled: Bool = false
    public private(set) var isAccessibilityTrusted: Bool = false
    public private(set) var isListening: Bool = false

    private var eventMonitor: Any?
    private var trustWatchTask: Task<Void, Never>?

    /// Wired by `AppDelegate`; lets hotkey changes refresh the visible
    /// app models (the popover row bindings are not involved here).
    public weak var discoveryService: AppDiscoveryService?

    private init() {
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    /// Called once at launch. Restores the user's saved choice without ever
    /// prompting: if hotkeys are enabled but trust has been revoked, they
    /// simply stay inactive until the user acts in Settings.
    public func restoreState() {
        isEnabled = UserDefaults.standard.bool(forKey: Constants.StorageKeys.hotkeysEnabled)
        QuickGestureManager.shared.restoreState()
        guard isEnabled, isAccessibilityTrusted else { return }
        startMonitoring()
    }

    /// User-facing switch from Settings. This is the only code path allowed
    /// to raise the Accessibility system prompt.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Constants.StorageKeys.hotkeysEnabled)
        QuickGestureManager.shared.setEnabled(enabled)

        if enabled {
            // Literal value of kAXTrustedCheckOptionPrompt; the global var
            // itself is shared mutable state, rejected by Swift 6.
            let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
            isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
            if isAccessibilityTrusted {
                startMonitoring()
                QuickGestureManager.shared.refreshTrust()
            } else {
                stopMonitoring()
                // The prompt only ever appears once; from here the grant can
                // only arrive via System Settings, so start looking for it.
                startWatchingForTrust()
            }
        } else {
            stopWatchingForTrust()
            stopMonitoring()
        }
    }

    /// Re-checks trust, e.g. when the app regains focus after the user
    /// granted Accessibility permission in System Settings. Starts
    /// monitoring immediately if the toggle is on and trust now exists.
    public func refreshTrust() {
        isAccessibilityTrusted = AXIsProcessTrusted()
        QuickGestureManager.shared.refreshTrust()
        FocusShieldManager.shared.refreshTrust()
        if isEnabled && isAccessibilityTrusted && !isListening {
            startMonitoring()
        }
    }

    /// Watches for Accessibility trust arriving while the user is over in
    /// System Settings, so the switch flips itself.
    ///
    /// macOS sends no notification when a TCC grant changes, and
    /// `AXIsProcessTrusted` is cheap, so a one-second poll is the
    /// mechanism Apple's own guidance leaves you with. It beats a
    /// "Check Again" button, which asks the user to do the polling.
    public func startWatchingForTrust(timeout: Duration = .seconds(300)) {
        trustWatchTask?.cancel()
        guard !isAccessibilityTrusted else { return }
        trustWatchTask = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refreshTrust()
                if self.isAccessibilityTrusted { return }
            }
        }
    }

    public func stopWatchingForTrust() {
        trustWatchTask?.cancel()
        trustWatchTask = nil
    }

    public func stopListening() {
        stopWatchingForTrust()
        stopMonitoring()
    }

    // MARK: - Event monitoring

    private func startMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // Global monitors are delivered on the main thread.
            MainActor.assumeIsolated {
                self.handleEvent(event)
            }
        }
        isListening = eventMonitor != nil
    }

    private func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isListening = false
    }

    private func handleEvent(_ event: NSEvent) {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontmost.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }

        // Command + Option + M -> toggle mute of the frontmost app.
        if event.modifierFlags.contains([.command, .option]) && event.keyCode == 46 {
            ChannelConfigStore.shared.toggleMute(for: bundleID)
            discoveryService?.refreshModelFromStore(for: bundleID)
        }
    }
}

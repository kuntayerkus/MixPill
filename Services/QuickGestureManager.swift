import Cocoa
import Foundation
import Observation

/// Quick Gestures: Option + Scroll Wheel anywhere on screen adjusts the
/// volume of the application that currently owns the active window — no
/// need to open the menu bar popover.
///
/// Shares the "Global Hotkeys" user preference and Accessibility grant
/// with `GlobalHotkeyManager`; both stay silent at launch and only prompt
/// when the user opts in from Settings.
@MainActor
@Observable
public final class QuickGestureManager {
    public static let shared = QuickGestureManager()

    public private(set) var isEnabled: Bool = false

    private var eventMonitor: Any?

    /// Wired by `AppDelegate`; lets gesture changes refresh the visible
    /// app models (the popover row bindings are not involved here).
    public weak var discoveryService: AppDiscoveryService?

    private init() {}

    /// Called once at launch. Restores the shared preference silently.
    public func restoreState() {
        isEnabled = UserDefaults.standard.bool(forKey: Constants.StorageKeys.hotkeysEnabled)
        guard isEnabled, AXIsProcessTrusted() else { return }
        startMonitoring()
    }

    /// Kept in sync with the Global Hotkeys toggle.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled && AXIsProcessTrusted() {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    /// Picks up a freshly granted Accessibility permission.
    public func refreshTrust() {
        guard isEnabled, AXIsProcessTrusted(), eventMonitor == nil else { return }
        startMonitoring()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { event in
            // Global monitors are delivered on the main thread.
            MainActor.assumeIsolated {
                self.handleScroll(event)
            }
        }
    }

    private func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard event.modifierFlags.contains(.option), event.scrollingDeltaY != 0 else { return }

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontmost.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }

        let adjustment: Float = event.scrollingDeltaY > 0 ? 0.05 : -0.05
        ChannelConfigStore.shared.adjustVolume(by: adjustment, for: bundleID)
        discoveryService?.refreshModelFromStore(for: bundleID)
    }
}

import Cocoa
import Foundation
import Observation

/// Focus Shield: keeps background applications from stealing keyboard focus
/// while the user is working.
///
/// macOS offers no public API to veto another process's activation, so the
/// shield uses the same heuristic focus utilities do: an activation that
/// happens *without recent user input* is a programmatic focus steal
/// (a background app calling `NSApp.activate`, a helper popping forward),
/// and the previously focused app is restored. A switch that follows real
/// clicks or keystrokes is respected — the shield never fights the user.
///
/// Requires Accessibility permission (global event monitoring); like the
/// hotkeys, the permission is only requested when the user turns the
/// shield on.
@MainActor
@Observable
public final class FocusShieldManager {
    public static let shared = FocusShieldManager()

    public private(set) var isShieldActive: Bool = false

    /// Activations with no user input in this window are treated as steals.
    private static let stealQuietPeriod: TimeInterval = 0.75
    /// Ignore activation events briefly after our own restore to avoid a
    /// re-entrancy loop.
    private static let restoreCooldown: TimeInterval = 1.0

    private var activationObserver: NSObjectProtocol?
    private var inputMonitor: Any?
    private var lastUserInput = Date.distantPast
    private var lastFrontmost: NSRunningApplication?
    private var restoreCooldownUntil = Date.distantPast

    private init() {}

    // MARK: - Lifecycle

    /// Called once at launch. Restores the saved preference silently — no
    /// permission prompt unless the user toggles the shield manually.
    public func restoreState() {
        let stored = UserDefaults.standard.bool(forKey: Constants.StorageKeys.focusShieldEnabled)
        guard stored, AXIsProcessTrusted() else { return }
        startMonitoring()
        isShieldActive = true
    }

    /// User-facing switch from the menu bar. Only code path allowed to
    /// raise the Accessibility prompt.
    public func setActive(_ active: Bool) {
        if active {
            // Literal value of kAXTrustedCheckOptionPrompt; the global var
            // itself is shared mutable state, rejected by Swift 6.
            let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
            guard AXIsProcessTrustedWithOptions(options) else {
                isShieldActive = false
                UserDefaults.standard.set(false, forKey: Constants.StorageKeys.focusShieldEnabled)
                return
            }
            startMonitoring()
        } else {
            stopMonitoring()
        }
        isShieldActive = active
        UserDefaults.standard.set(active, forKey: Constants.StorageKeys.focusShieldEnabled)
    }

    /// Re-checks trust when the app regains focus after the user granted
    /// Accessibility permission in System Settings.
    public func refreshTrust() {
        let stored = UserDefaults.standard.bool(forKey: Constants.StorageKeys.focusShieldEnabled)
        guard stored, !isShieldActive, AXIsProcessTrusted() else { return }
        startMonitoring()
        isShieldActive = true
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard inputMonitor == nil else { return }

        lastFrontmost = NSWorkspace.shared.frontmostApplication
        lastUserInput = .now

        inputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { _ in
            // Global monitors are delivered on the main thread.
            MainActor.assumeIsolated {
                self.lastUserInput = .now
            }
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.handleActivation(for: app)
            }
        }
    }

    private func stopMonitoring() {
        if let inputMonitor {
            NSEvent.removeMonitor(inputMonitor)
            self.inputMonitor = nil
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    // MARK: - Steal detection

    private func handleActivation(for newApp: NSRunningApplication?) {
        guard isShieldActive, let newApp else { return }

        let previous = lastFrontmost
        lastFrontmost = newApp

        guard Date.now > restoreCooldownUntil else { return }
        guard let previous, previous.bundleIdentifier != newApp.bundleIdentifier else { return }
        guard previous.activationPolicy == .regular else { return }

        // Recent user input means the user switched on purpose.
        guard Date.now.timeIntervalSince(lastUserInput) > Self.stealQuietPeriod else { return }

        restoreCooldownUntil = Date.now.addingTimeInterval(Self.restoreCooldown)
        MixPillLog.log("FocusShield: restored focus to \(previous.localizedName ?? previous.bundleIdentifier ?? "previous app")")
        previous.activate()
    }
}

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

    /// The user has asked for the shield and macOS has not granted
    /// Accessibility yet.
    ///
    /// A state of its own, because "off" and "asked for but not permitted"
    /// need different words on screen and different behaviour on the next
    /// launch. Without it the switch bounced back with no explanation.
    public private(set) var isAwaitingPermission: Bool = false

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
        guard stored else { return }
        guard AXIsProcessTrusted() else {
            // Asked for, not permitted — say so rather than quietly
            // presenting an off switch the user already turned on.
            isAwaitingPermission = true
            return
        }
        startMonitoring()
        isShieldActive = true
    }

    /// User-facing switch from the menu bar. Only code path allowed to
    /// raise the Accessibility prompt.
    ///
    /// `AXIsProcessTrustedWithOptions` answers for *this instant* and then
    /// puts the prompt on screen; it cannot report what the user is about
    /// to do in System Settings, and it never returns `true` on the call
    /// that asks. Treating that `false` as the user's answer was the bug:
    /// the preference was rewritten to `false`, and `refreshTrust` — which
    /// requires it to be `true` — could then never turn the shield on. The
    /// permission was granted, and nothing in MixPill was left that could
    /// notice.
    ///
    /// So the request is recorded first and the grant is waited for.
    public func setActive(_ active: Bool) {
        guard active else {
            stopMonitoring()
            isShieldActive = false
            isAwaitingPermission = false
            UserDefaults.standard.set(false, forKey: Constants.StorageKeys.focusShieldEnabled)
            return
        }

        UserDefaults.standard.set(true, forKey: Constants.StorageKeys.focusShieldEnabled)

        // Literal value of kAXTrustedCheckOptionPrompt; the global var
        // itself is shared mutable state, rejected by Swift 6.
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        guard AXIsProcessTrustedWithOptions(options) else {
            isShieldActive = false
            isAwaitingPermission = true
            // The prompt appears once and macOS sends nothing when the
            // grant lands, so borrow the poll the hotkeys already run.
            GlobalHotkeyManager.shared.startWatchingForTrust()
            MixPillLog.log("FocusShield: waiting for Accessibility permission")
            return
        }

        isAwaitingPermission = false
        startMonitoring()
        isShieldActive = true
    }

    /// Re-checks trust when the app regains focus after the user granted
    /// Accessibility permission in System Settings, or when the hotkey
    /// manager's trust poll ticks.
    public func refreshTrust() {
        let stored = UserDefaults.standard.bool(forKey: Constants.StorageKeys.focusShieldEnabled)
        guard stored, !isShieldActive else { return }
        guard AXIsProcessTrusted() else {
            isAwaitingPermission = true
            return
        }
        isAwaitingPermission = false
        startMonitoring()
        isShieldActive = true
        MixPillLog.log("FocusShield: Accessibility granted; the shield is on")
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

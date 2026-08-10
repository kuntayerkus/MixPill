import Cocoa
import SwiftUI

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?

    public let permissionManager = PermissionManager()
    public let coreBridge = CoreBridge()
    public lazy var discoveryService = AppDiscoveryService(bridge: coreBridge)
    public let presetManager = PresetManager()

    public func applicationDidFinishLaunching(_ aNotification: Notification) {
        guard !terminateIfAlreadyRunning() else { return }

        // Wire the desired-state store to its transport.
        ChannelConfigStore.shared.bridge = coreBridge

        SceneAutomationManager.shared.presetManager = presetManager
        SceneAutomationManager.shared.discoveryService = discoveryService
        GlobalHotkeyManager.shared.discoveryService = discoveryService
        QuickGestureManager.shared.discoveryService = discoveryService

        // Shortcuts and Focus filters run outside the view hierarchy.
        MixPillIntentBridge.shared.discoveryService = discoveryService
        MixPillIntentBridge.shared.presetManager = presetManager

        // Bring the audio engine service up immediately — even before any
        // permission is granted — so it is warm when configuration lands.
        coreBridge.connect()

        discoveryService.startDiscovery()

        GlobalHotkeyManager.shared.restoreState()
        FocusShieldManager.shared.restoreState()
        UpdateService.shared.start()

        if !UserDefaults.standard.bool(forKey: Constants.StorageKeys.hasCompletedOnboarding) {
            showOnboardingWindow()
        }
    }

    /// Hands over to an already-running copy and quits.
    ///
    /// LaunchServices only prevents relaunching the *same* bundle, so two
    /// copies at different paths — a build in Xcode's DerivedData and one
    /// in /Applications, say — will happily run at once. For most apps
    /// that is untidy; for this one it is a real fault: both copies open
    /// process taps on the same applications, each tap mutes the app it
    /// captures, and the audio ends up doubled or fighting itself.
    private func terminateIfAlreadyRunning() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? "com.mixpill.app"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let existing = others.first else { return false }

        NSLog("MixPill: another copy is already running (pid \(existing.processIdentifier)); handing over.")
        existing.activate()
        NSApp.terminate(nil)
        return true
    }

    /// Coming back to MixPill is the moment a user has just finished
    /// granting something in System Settings, so re-check trust then.
    public func applicationDidBecomeActive(_ notification: Notification) {
        permissionManager.checkPermissions()
        GlobalHotkeyManager.shared.refreshTrust()
    }

    public func applicationWillTerminate(_ aNotification: Notification) {
        GlobalHotkeyManager.shared.stopListening()
        // Note: discovery/capture deliberately NOT stopped here. MixPillCore
        // keeps capturing and mixing after the UI quits — that is the point
        // of the decomposition.
        discoveryService.stopDiscovery()
    }

    @objc public func openSettingsWindow() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
                .environment(permissionManager)
                .environment(presetManager)
                .environment(discoveryService)
                .environment(coreBridge)

            let hostingController = NSHostingController(rootView: settingsView)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 650, height: 450),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )

            window.title = "MixPill Settings"
            window.contentViewController = hostingController
            window.center()
            window.setFrameAutosaveName("Settings")
            window.isReleasedWhenClosed = false
            self.settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Onboarding

    private func showOnboardingWindow() {
        guard onboardingWindow == nil else {
            onboardingWindow?.makeKeyAndOrderFront(nil)
            return
        }

        let onboardingView = OnboardingView { [weak self] in
            self?.onboardingWindow?.close()
        }
        .environment(permissionManager)
        .environment(coreBridge)
        .environment(discoveryService)

        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Welcome to MixPill"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.onboardingWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === onboardingWindow else { return }
        // Dismissing onboarding in any way (finish, "Set Up Later", or the
        // close button) marks it done so it never reappears uninvited.
        UserDefaults.standard.set(true, forKey: Constants.StorageKeys.hasCompletedOnboarding)
        onboardingWindow = nil
    }
}

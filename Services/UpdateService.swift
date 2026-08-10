import Foundation
import Observation
import Sparkle

/// Software update, via Sparkle.
///
/// MixPill ships outside the Mac App Store, so nothing else will ever hand
/// a fix to someone who already downloaded it. Without this, a defect found
/// after release — the kind of thing that turns out to be a 30 dB level
/// loss on multichannel interfaces — stays on every installed copy forever.
///
/// Checks are automatic and quiet: Sparkle asks permission the first time,
/// then looks once a day and only interrupts when there is something to
/// install. Nothing is sent anywhere but a request for the appcast.
@MainActor
@Observable
public final class UpdateService: NSObject {
    public static let shared = UpdateService()

    private var controller: SPUStandardUpdaterController?

    /// Whether a check can start right now.
    ///
    /// Read on demand rather than observed. Sparkle exposes this as a plain
    /// Obj-C property, and binding to it with a Swift key path needs it to
    /// be `dynamic` — which holds on some toolchains and not others, so the
    /// KVO version compiled locally and failed on CI's Xcode 16.4. A
    /// straight read works everywhere and is accurate at the moment the
    /// button is drawn, which is the only moment that matters.
    public var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    private override init() {
        super.init()
    }

    /// Starts the updater. Called once at launch.
    public func start() {
        guard controller == nil else { return }

        // `startingUpdater: true` begins the scheduled background checks;
        // Sparkle handles the first-run permission prompt itself.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
    }

    /// The user asked to check now.
    public func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    public var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Version string for the Settings footer and the About panel.
    public var versionDescription: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(short) (\(build))"
    }
}

import Foundation
import AppKit

/// Central recovery coordinator for the core service. Owns every
/// "the audio world changed under us" path: system sleep/wake, device
/// topology changes, `coreaudiod` restarts, canonical clock changes, and
/// manual resets from the Diagnostics panel.
///
/// Recovery playbook:
/// 1. Verify CoreAudio HAL actually answers (give `coreaudiod` time to
///    come back when it crashed).
/// 2. Re-snap the canonical processing rate to the interface clock.
/// 3. Rebuild every output engine from scratch (old device IDs are
///    untrusted after a daemon restart).
/// 4. Lift capture backoff debt and re-arm every stream.
final class CoreResilienceEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mixpill.core.resilience", qos: .userInitiated)
    private let stateLock = UnfairLock()

    private let registry: DeviceRegistry
    private let mixer: LowLatencyMixerEngine
    private let capture: ProcessTapCapture

    private var lastKnownDeviceUIDs: Set<String> = []
    private var lastKnownDefaultUID: String?
    private var recoveryInFlight = false
    private var lastRecoveryReasonValue = "None"
    private var lastRecoveryDateValue: Date?

    /// Supplies the current discovery snapshot for tap re-arming.
    var currentProcessesProvider: () -> [AudioProcessRegistry.AudioProcess] = { [] }
    /// Notifies the service so the UI can show the recovery event.
    var onRecovery: ((_ reason: String, _ date: Date) -> Void)?

    init(registry: DeviceRegistry, mixer: LowLatencyMixerEngine, capture: ProcessTapCapture) {
        self.registry = registry
        self.mixer = mixer
        self.capture = capture
    }

    var lastRecoveryReason: String {
        stateLock.withLock { lastRecoveryReasonValue }
    }

    var lastRecoveryDate: Date? {
        stateLock.withLock { lastRecoveryDateValue }
    }

    // MARK: - Lifecycle

    func start() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.prepareForSleep()
        }

        workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recover(reason: "System wake")
        }

        registry.addObserver { [weak self] in
            self?.handleTopologyChange()
        }

        // Remember the boot topology and snap the canonical rate to the
        // interface clock before any audio flows far.
        registry.refresh()
        lastKnownDeviceUIDs = Set(registry.outputDevices().map(\.uid))
        lastKnownDefaultUID = registry.defaultOutputDeviceUID()
        if let rate = registry.defaultDeviceNominalSampleRate() {
            AudioResamplerService.shared.matchHardwareSampleRate(rate)
        }
        registry.startListening()
    }

    // MARK: - Sleep / wake

    private func prepareForSleep() {
        // Best-effort teardown before the kernel suspends us; the wake
        // recovery rebuilds everything regardless.
        capture.stopAll()
        mixer.stopAllEngines()
    }

    // MARK: - Topology changes

    private func handleTopologyChange() {
        let snapshot = registry.snapshot()
        let uids = Set(snapshot.devices.map(\.uid))

        if snapshot.devices.isEmpty {
            recoverFromCoreAudioDaemonRestart()
            return
        }

        queue.async {
            let topologyChanged = uids != self.lastKnownDeviceUIDs
            self.lastKnownDeviceUIDs = uids

            // A change of default output matters as much as a change of
            // topology now: each tap is bound to a specific device's stream
            // format, and which channels carry an app's stereo pair is a
            // property of that device. Switching from a 64-channel desk to
            // the built-in speakers invalidates both.
            let defaultChanged = snapshot.defaultDeviceUID != self.lastKnownDefaultUID
            self.lastKnownDefaultUID = snapshot.defaultDeviceUID

            if topologyChanged {
                self.recoverLocked(reason: "Audio configuration change")
            } else if defaultChanged {
                self.recoverLocked(reason: "Default output changed")
            }
        }
    }

    /// Every AudioDeviceID is invalid while `coreaudiod` is down. Poll
    /// until the daemon answers again, then rebuild from a clean slate.
    private func recoverFromCoreAudioDaemonRestart() {
        queue.async {
            self.recordRecovery("CoreAudio daemon restart")

            for _ in 0..<8 {
                Thread.sleep(forTimeInterval: 0.5)
                if self.registry.refresh(), !self.registry.outputDevices().isEmpty {
                    self.lastKnownDeviceUIDs = Set(self.registry.outputDevices().map(\.uid))
                    self.rebuildLocked()
                    return
                }
            }

            MixPillCoreLog.log("CoreResilienceEngine: CoreAudio daemon still unreachable after retries; watchdog will keep trying")
        }
    }

    // MARK: - Recovery core

    func recover(reason: String) {
        queue.async {
            self.recoverLocked(reason: reason)
        }
    }

    /// One-click recovery from the Diagnostics panel.
    func performManualRecovery() {
        recover(reason: "Manual reset")
    }

    private func recoverLocked(reason: String) {
        guard !recoveryInFlight else { return }
        recoveryInFlight = true
        defer { recoveryInFlight = false }

        recordRecovery(reason)
        rebuildLocked()
        MixPillCoreLog.log("CoreResilienceEngine: recovery complete (\(reason))")
    }

    private func rebuildLocked() {
        registry.refresh()
        lastKnownDeviceUIDs = Set(registry.outputDevices().map(\.uid))
        lastKnownDefaultUID = registry.defaultOutputDeviceUID()

        if let rate = registry.defaultDeviceNominalSampleRate() {
            AudioResamplerService.shared.matchHardwareSampleRate(rate)
        }

        mixer.rebuildAllEngines()

        // Taps are bound to the audio world that existed when they were
        // created, so a daemon restart or clock change invalidates them
        // just as surely as it invalidates device ids.
        capture.restartAll(with: currentProcessesProvider())

        let reason = lastRecoveryReason
        let date = lastRecoveryDate ?? .now
        onRecovery?(reason, date)
    }

    private func recordRecovery(_ reason: String) {
        stateLock.withLock {
            lastRecoveryReasonValue = reason
            lastRecoveryDateValue = Date()
        }
    }
}

import Foundation

/// Smart Ducking: dips everything else while someone is on a call.
///
/// The signal is **who has the microphone open**, not a list of app names.
/// A process holding an input stream is, by definition, in a call — that is
/// what `kAudioProcessPropertyIsRunningInput` reports, and the HAL knows it
/// for every app on the machine.
///
/// The previous version hardcoded six bundle identifiers (Zoom, Teams,
/// Discord, Webex, Slack, Teams 2). FaceTime did not duck. Google Meet in a
/// browser did not duck. Telegram, Signal, Jitsi, and anything released
/// after the list was written did not duck. It was also wrong in the other
/// direction: Discord sitting idle in the background counted as a call the
/// moment it made any sound at all.
///
/// Ducking still requires the call app to actually be producing audio, so
/// an open-but-silent meeting window does not hold everything down.
final class DuckingController: @unchecked Sendable {
    /// Background apps dip to 20% while someone is speaking.
    private static let duckedMultiplier: Float = 0.2
    /// Output level above which a call app counts as "someone is talking".
    private static let voiceLevelThreshold: Float = 0.02

    private let mixer: LowLatencyMixerEngine
    private let lock = UnfairLock()
    private var enabled = false
    private var active = false
    /// Bundle identifiers currently holding an input stream.
    private var callParticipants: Set<String> = []

    init(mixer: LowLatencyMixerEngine) {
        self.mixer = mixer
    }

    func setEnabled(_ isEnabled: Bool) {
        let shouldRelease: Bool = lock.withLock {
            guard enabled != isEnabled else { return false }
            enabled = isEnabled
            guard !isEnabled else { return false }
            let wasActive = active
            active = false
            return wasActive
        }

        if shouldRelease {
            mixer.setDuckingMultiplier(1.0, excludingVoIP: [])
        }
    }

    func isEnabled() -> Bool {
        lock.withLock { enabled }
    }

    /// Called by the discovery layer whenever the set of processes holding
    /// the microphone changes.
    func updateCallParticipants(_ bundleIDs: [String]) {
        let released: Bool = lock.withLock {
            let updated = Set(bundleIDs)
            guard updated != callParticipants else { return false }
            callParticipants = updated
            // Nobody is on a call any more: lift immediately rather than
            // waiting for the next metering flush, which only carries apps
            // that produced audio.
            guard updated.isEmpty, active else { return false }
            active = false
            return true
        }

        if released {
            mixer.setDuckingMultiplier(1.0, excludingVoIP: [])
        }
    }

    /// Called on every metering flush.
    func evaluate(levels: [(bundleID: String, rms: Float, peak: Float)]) {
        enum Action { case none, duck(Set<String>), release }

        let action: Action = lock.withLock {
            guard enabled, !callParticipants.isEmpty else { return .none }

            let someoneIsTalking = levels.contains { sample in
                callParticipants.contains(sample.bundleID) && sample.rms > Self.voiceLevelThreshold
            }
            guard someoneIsTalking != active else { return .none }
            active = someoneIsTalking
            return someoneIsTalking ? .duck(callParticipants) : .release
        }

        switch action {
        case .none:
            break
        case .duck(let participants):
            mixer.setDuckingMultiplier(Self.duckedMultiplier, excludingVoIP: participants)
        case .release:
            mixer.setDuckingMultiplier(1.0, excludingVoIP: [])
        }
    }
}

import Foundation

/// XPC contract between the MixPill UI process and the MixPillCore
/// service. Deliberately `@objc` with primitive/`Data` arguments only:
/// that is the shape `NSXPCConnection` can encode natively, and it keeps
/// the two processes free to evolve their internal models independently.
///
/// Direction of ownership:
/// - UI → core (`MixPillCoreControlProtocol`): desired state and commands.
/// - Core → UI (`MixPillCoreEventsProtocol`): observed reality.
///
/// If the UI crashes or quits, the core keeps capturing, mixing and
/// playing audio with the last configuration it received — audio
/// continuity never depends on the interface process.

@objc(MixPillCoreControlProtocol)
public protocol MixPillCoreControlProtocol {
    /// Applies a full desired-state snapshot. Sent on connect and again
    /// whenever the UI wants to resynchronize. `reply` reports success.
    func applyConfiguration(_ data: Data, reply: @escaping @Sendable (_ success: Bool) -> Void)

    /// Creates or updates one app channel. Payload: `ChannelConfig`.
    func applyChannel(_ data: Data)

    /// Creates or updates several channels at once. Payload:
    /// `[ChannelConfig]`.
    ///
    /// The interface re-sends channel state whenever the discovered app
    /// list changes, and that fires every time *any* application starts or
    /// stops playing. One message per channel meant twenty XPC round trips
    /// — each one hopping two dispatch queues and redesigning a biquad —
    /// because somebody opened a video in another window.
    func applyChannels(_ data: Data)

    /// Removes a channel (app quit or capture permanently abandoned).
    func removeChannel(_ bundleID: String)

    /// Whether the level meters are visible right now.
    ///
    /// Metering never stops — Smart Ducking depends on it and has to keep
    /// working with the interface closed — but it only needs to run fast
    /// enough to look smooth while someone is watching it.
    func setMeterDisplayActive(_ active: Bool)

    func setMasterVolume(_ volume: Float)
    func setLowLatencyEnabled(_ enabled: Bool)
    func setDuckingEnabled(_ enabled: Bool)

    /// Asks the core to move the macOS system default output onto the
    /// device with this UID, or to report failure.
    func setDefaultOutputDeviceUID(_ uid: String, reply: @escaping @Sendable (_ success: Bool) -> Void)

    /// Answers a `DiagnosticsDTO` payload.
    func requestDiagnostics(reply: @escaping @Sendable (_ data: Data) -> Void)

    /// One-click engine rebuild (the Diagnostics panel reset).
    func performManualRecovery()
}

@objc(MixPillCoreEventsProtocol)
public protocol MixPillCoreEventsProtocol {
    /// Sent once after the service finished booting its subsystems.
    func coreDidBecomeReady()

    /// Discovered app list changed. Payload: `[CoreAppInfo]`.
    func appsChanged(_ data: Data)

    /// Batched metering. Payload: `LevelsPayload` (≈10 Hz).
    func levelsChanged(_ data: Data)

    /// Device topology / default output changed. Payload: `DevicesPayload`.
    func devicesChanged(_ data: Data)

    /// A heavyweight recovery (wake, coreaudiod restart, manual) ran.
    func recoveryOccurred(reason: String, date: Date)

    /// Reports whether the core can currently capture application audio.
    ///
    /// This is observed, not predicted: it reflects whether
    /// `AudioHardwareCreateProcessTap` actually succeeded. Guessing from a
    /// TCC status instead would be wrong in both directions — MixPill can
    /// tap without holding a microphone grant, and holding one guarantees
    /// nothing.
    func captureAvailabilityChanged(available: Bool, reason: String)
}

/// JSON helpers both sides use for the `Data` payloads above.
public enum MixPillCoder {
    public static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

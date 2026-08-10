import Foundation

/// Cross-target identifiers shared by the MixPill UI and the MixPillCore
/// XPC service. Keeping them in one place guarantees both ends of every
/// IPC or HAL lookup agree on the exact string, which is what makes the
/// decomposition safe.
public enum MixPillXPC {
    /// Service name of the bundled XPC service, as looked up by
    /// `NSXPCConnection(serviceName:)` inside `Contents/XPCServices`. For
    /// application XPC services this must equal the service's bundle
    /// identifier.
    ///
    /// Note this is deliberately *not* a Mach service name: a bundled
    /// `ServiceType = Application` service is never registered in the
    /// bootstrap namespace, so `NSXPCConnection(machServiceName:)` can
    /// never reach it.
    public static let serviceName = "com.mixpill.core"
    public static let coreBundleIdentifier = "com.mixpill.core"
}


/// Canonical processing format constants shared by capture, resampling and
/// the mixer. The pipeline speaks Float32 stereo everywhere; the rate
/// snaps to the connected interface's clock (48 kHz until detected).
public enum CoreAudioFormat {
    public static let baseSampleRate: Double = 48_000
    public static let channelCount: UInt32 = 2
    public static let defaultAppVolume: Float = 1.0

    /// Hardware clocks the canonical pipeline may snap to.
    public static let supportedHardwareRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000
    ]
}

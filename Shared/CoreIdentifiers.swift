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


/// Applications MixPill must never capture.
///
/// A tapped app is muted at source and re-played from the stereo pair
/// MixPill captured. For a digital audio workstation that is destructive:
/// its monitoring latency grows by the capture block, its multi-output
/// routing is silenced, and any hiccup in MixPill becomes a dropout in a
/// recording session.
///
/// The list lives here rather than in the interface because the engine has
/// to act on it the moment a process appears — waiting for the UI to send
/// a channel configuration would mean tapping a DAW for the first second
/// of its life, which is exactly when someone is likely to be recording.
public enum DAWDetection {
    private static let bundleIDPrefixes = [
        "com.apple.logic",
        "com.ableton.live",
        "com.avid.protools",
        "net.steinberg.cubase",
        "net.steinberg.nuendo",
        "com.image-line.flstudio",
        "com.presonus.studioone",
        "com.bitwig.bitwigstudio",
        "com.reaper.reaper",
        "com.cockos.reaper",
        "com.apple.garageband"
    ]

    public static func isDAW(bundleID: String) -> Bool {
        let lowered = bundleID.lowercased()
        return bundleIDPrefixes.contains { lowered.hasPrefix($0) }
    }
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

/// Routing target for a channel strip. `deviceUID == ""` is the sentinel
/// for "follow the system default output".
public struct MixEngineKey: Hashable, Sendable {
    public let deviceUID: String
    public let pairIndex: Int

    public init(deviceUID: String, pairIndex: Int) {
        self.deviceUID = deviceUID
        self.pairIndex = pairIndex
    }

    public static let systemDefault = MixEngineKey(deviceUID: "", pairIndex: 0)

    /// Parses the wire pair id ("system-default" or "deviceUID#pairIndex").
    ///
    /// Two things this has to survive. First, malformed input: the value is
    /// read back out of `UserDefaults`, and `"#"` used to split into an
    /// *empty* array — Swift drops empty subsequences — so indexing `[0]`
    /// crashed the audio service outright.
    ///
    /// Second, a device UID is an arbitrary string chosen by its driver and
    /// may contain "#" itself. Splitting on the first separator resolved
    /// `"Focusrite#1"` (that device, pair 0) as device `"Focusrite"`, pair 1
    /// — silently the wrong device *and* the wrong channel pair. Splitting
    /// on the last one, and only when the tail is actually a number, gets
    /// both cases right while keeping the on-disk format unchanged.
    public static func parse(pairID: String) -> MixEngineKey {
        guard pairID != "system-default", !pairID.isEmpty else { return .systemDefault }

        guard let separator = pairID.lastIndex(of: "#") else {
            return MixEngineKey(deviceUID: pairID, pairIndex: 0)
        }

        let uid = String(pairID[pairID.startIndex..<separator])
        let tail = pairID[pairID.index(after: separator)...]
        guard !uid.isEmpty, let pairIndex = Int(tail), pairIndex >= 0 else {
            // Not our encoding after all — the "#" belongs to the UID.
            return MixEngineKey(deviceUID: pairID, pairIndex: 0)
        }
        return MixEngineKey(deviceUID: uid, pairIndex: pairIndex)
    }

    public var pairID: String {
        deviceUID.isEmpty ? "system-default" : (pairIndex == 0 ? deviceUID : "\(deviceUID)#\(pairIndex)")
    }
}

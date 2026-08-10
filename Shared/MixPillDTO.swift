import Foundation

/// Wire types exchanged between the MixPill UI and the MixPillCore XPC
/// service. Every type is `Codable` so it can travel as `Data` over the
/// XPC connection, and `Sendable` so both Swift 6 sides can use them
/// without isolation warnings.
///
/// The UI owns *desired state* (volumes, EQ, routing, toggles, presets);
/// the core owns *runtime state* (streams, engines, levels, devices).
/// These DTOs are the entire surface where the two meet.

/// One discovered audio-producing application, reported core → UI.
public struct CoreAppInfo: Codable, Hashable, Sendable {
    public let bundleID: String
    public let name: String
    /// Sending audio to an output device right now.
    public let isPlaying: Bool
    /// Holding an input stream right now — the signal MixPill uses to know
    /// someone is on a call.
    public let isCapturingInput: Bool

    public init(bundleID: String, name: String, isPlaying: Bool = false, isCapturingInput: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.isPlaying = isPlaying
        self.isCapturingInput = isCapturingInput
    }
}

/// The complete per-app channel configuration, pushed UI → core whenever
/// any field changes. The core applies it idempotently.
public struct ChannelConfig: Codable, Hashable, Sendable {
    public var bundleID: String
    public var volume: Float
    public var isMuted: Bool
    /// Five parametric band gains in dB (100 Hz, 400 Hz, 1 kHz, 4 kHz, 10 kHz).
    public var eqGains: [Float]
    /// True when every DSP stage is bypassed (DAW Direct mode).
    public var processingBypassed: Bool
    /// Block-level noise gate threshold, 0 = off.
    public var noiseGateThreshold: Float
    /// Feed-forward dynamic range compression (Night Mode).
    public var compressorEnabled: Bool
    /// Routing target pair id ("system-default" or "deviceUID#pairIndex").
    public var routePairID: String

    public init(
        bundleID: String,
        volume: Float,
        isMuted: Bool,
        eqGains: [Float],
        processingBypassed: Bool,
        noiseGateThreshold: Float,
        compressorEnabled: Bool,
        routePairID: String
    ) {
        self.bundleID = bundleID
        self.volume = volume
        self.isMuted = isMuted
        self.eqGains = eqGains
        self.processingBypassed = processingBypassed
        self.noiseGateThreshold = noiseGateThreshold
        self.compressorEnabled = compressorEnabled
        self.routePairID = routePairID
    }
}

/// Full desired-state snapshot sent once when the UI (re)connects, so the
/// core never depends on the UI staying alive for audio to keep playing.
public struct EngineConfiguration: Codable, Sendable {
    public var masterVolume: Float
    public var lowLatencyEnabled: Bool
    public var duckingEnabled: Bool
    public var channels: [ChannelConfig]

    public init(
        masterVolume: Float,
        lowLatencyEnabled: Bool,
        duckingEnabled: Bool,
        channels: [ChannelConfig]
    ) {
        self.masterVolume = masterVolume
        self.lowLatencyEnabled = lowLatencyEnabled
        self.duckingEnabled = duckingEnabled
        self.channels = channels
    }
}

/// One metering sample, batched core → UI at 10 Hz.
public struct LevelSample: Codable, Sendable {
    public let bundleID: String
    public let rms: Float
    public let peak: Float

    public init(bundleID: String, rms: Float, peak: Float) {
        self.bundleID = bundleID
        self.rms = rms
        self.peak = peak
    }
}

public struct LevelsPayload: Codable, Sendable {
    public let samples: [LevelSample]

    public init(samples: [LevelSample]) {
        self.samples = samples
    }
}

/// Physical output device as enumerated by the core's HAL registry.
public struct OutputDeviceDTO: Codable, Hashable, Sendable {
    public let uid: String
    public let name: String
    public let channelCount: Int

    public init(uid: String, name: String, channelCount: Int) {
        self.uid = uid
        self.name = name
        self.channelCount = channelCount
    }
}

/// One routable stereo target: "System Default" or a channel pair.
///
/// `deviceName` and `channelLabel` are carried separately from
/// `displayName` so the UI can group pairs under their device. A
/// 64-channel interface contributes 32 targets; as one flat list that is
/// unusable, and as "Device ▸ Outputs 1-2" it is obvious.
public struct RoutingColumnDTO: Codable, Hashable, Sendable {
    public let pairID: String
    public let displayName: String
    /// nil for "System Default".
    public let deviceName: String?
    /// e.g. "Outputs 3-4", or nil when the device has a single pair.
    public let channelLabel: String?

    public init(pairID: String, displayName: String, deviceName: String? = nil, channelLabel: String? = nil) {
        self.pairID = pairID
        self.displayName = displayName
        self.deviceName = deviceName
        self.channelLabel = channelLabel
    }
}

public struct DevicesPayload: Codable, Sendable {
    public let devices: [OutputDeviceDTO]
    public let defaultDeviceUID: String?
    public let columns: [RoutingColumnDTO]

    public init(devices: [OutputDeviceDTO], defaultDeviceUID: String?, columns: [RoutingColumnDTO]) {
        self.devices = devices
        self.defaultDeviceUID = defaultDeviceUID
        self.columns = columns
    }
}

/// Diagnostics panel snapshot, answered on demand core → UI.
public struct DiagnosticsDTO: Codable, Sendable {
    public var engineHealthy: Bool
    public var ioBufferFrames: Int
    public var ioLatencyMS: Double
    public var ringCapacityFrames: Int
    public var activeTaps: Int
    public var activeConverters: Int
    public var hardwareSampleRate: Double?
    public var lastRecoveryReason: String
    public var lastRecoveryDate: Date?

    public init() {
        engineHealthy = true
        ioBufferFrames = 0
        ioLatencyMS = 0
        ringCapacityFrames = 0
        activeTaps = 0
        activeConverters = 0
        hardwareSampleRate = nil
        lastRecoveryReason = "None"
        lastRecoveryDate = nil
    }
}


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
    /// Whether the engine actually holds a tap on this app.
    ///
    /// False means MixPill is not in this app's signal path at all — it is
    /// in DAW Direct, or its tap failed — so the channel strip's volume,
    /// mute and EQ do nothing. The interface has to say so rather than
    /// offering a fader that moves without changing the sound.
    public let isCaptured: Bool

    public init(
        bundleID: String,
        name: String,
        isPlaying: Bool = false,
        isCapturingInput: Bool = false,
        isCaptured: Bool = true
    ) {
        self.bundleID = bundleID
        self.name = name
        self.isPlaying = isPlaying
        self.isCapturingInput = isCapturingInput
        self.isCaptured = isCaptured
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
    /// Gain the output limiter is taking off the summed mix right now, in
    /// dB, 0 when it is idle.
    ///
    /// It rides with the meters because it is a meter: it moves with the
    /// programme material, and it is the only honest answer to a channel
    /// boost that produces no extra loudness on an already-loud source.
    public let limiterReductionDB: Float

    public init(samples: [LevelSample], limiterReductionDB: Float = 0) {
        self.samples = samples
        self.limiterReductionDB = limiterReductionDB
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
    /// The rate the mixer is actually running at, which follows the
    /// interface clock. The EQ curve is drawn from the same biquad design
    /// the engine runs, so it has to be evaluated at the same rate or the
    /// picture stops matching the sound above 48 kHz.
    public let canonicalSampleRate: Double

    public init(
        devices: [OutputDeviceDTO],
        defaultDeviceUID: String?,
        columns: [RoutingColumnDTO],
        canonicalSampleRate: Double = CoreAudioFormat.baseSampleRate
    ) {
        self.devices = devices
        self.defaultDeviceUID = defaultDeviceUID
        self.columns = columns
        self.canonicalSampleRate = canonicalSampleRate
    }
}

/// What the engine is *actually* applying to one channel, read back from
/// the live parameter block the render thread reads.
///
/// Deliberately not derived from the interface's own model. Those two are
/// separated by a preference file, an XPC hop and a DSP parameter store,
/// and when a fader appears not to work the only useful question is which
/// side of that chain the value stopped at. A panel that re-displays the
/// interface's own number cannot answer it; this is the engine's answer.
public struct AppliedChannelDTO: Codable, Hashable, Sendable {
    public let bundleID: String
    /// Linear gain the render pass multiplies by, with mute and Smart
    /// Ducking's target folded in — the number, not the intent. (Ducking
    /// is smoothed over 0.4 s on the render thread, so this is where that
    /// ramp is heading rather than exactly where it is this millisecond.)
    public let appliedGain: Float
    public let isMuted: Bool
    public let eqEnabled: Bool
    public let processingBypassed: Bool

    public init(
        bundleID: String,
        appliedGain: Float,
        isMuted: Bool,
        eqEnabled: Bool,
        processingBypassed: Bool
    ) {
        self.bundleID = bundleID
        self.appliedGain = appliedGain
        self.isMuted = isMuted
        self.eqEnabled = eqEnabled
        self.processingBypassed = processingBypassed
    }
}

/// Diagnostics panel snapshot, answered on demand core → UI.
public struct DiagnosticsDTO: Codable, Sendable {
    public var engineHealthy: Bool
    public var ioBufferFrames: Int
    public var ioLatencyMS: Double
    public var ringCapacityFrames: Int
    public var activeTaps: Int
    /// Output units currently running. Zero with nothing playing is the
    /// healthy idle state, not a fault — MixPill releases the device so it
    /// can sleep.
    public var activeEngines: Int
    public var hardwareSampleRate: Double?
    public var lastRecoveryReason: String
    public var lastRecoveryDate: Date?
    /// Ring dropouts since the service started. A starvation is an empty
    /// read on a channel that was playing — the failure that shows up
    /// under load — and it is counted apart from a partial read because
    /// one is the stream stopping and the other a hole punched in it.
    public var ringUnderruns: Int
    public var ringStarvations: Int
    public var ringDrops: Int
    /// Times the occupancy controller has moved a read position back onto
    /// its target. Not a dropout: it is the correction that stops one, and
    /// a few per hour is simply what two unsynchronised audio clocks look
    /// like. A number that climbs every few seconds means something is
    /// stalling the IO cycle repeatedly, which is worth showing.
    public var ringResyncs: Int
    /// How far the rate loop is bending the stream to hold the two clocks
    /// together, in parts per million, worst channel.
    ///
    /// This is the mechanism made visible. Two audio clocks are never
    /// identical, and a number that sits steady at a few dozen ppm is the
    /// loop doing exactly its job. One pinned at the limit means something
    /// a resampler cannot fix — a device that stopped, or a rate the engine
    /// was never told about.
    public var clockCorrectionPPM: Int
    /// The gains the engine is really applying, per channel.
    public var appliedChannels: [AppliedChannelDTO]

    public init() {
        engineHealthy = true
        ioBufferFrames = 0
        ioLatencyMS = 0
        ringCapacityFrames = 0
        activeTaps = 0
        activeEngines = 0
        hardwareSampleRate = nil
        lastRecoveryReason = "None"
        lastRecoveryDate = nil
        ringUnderruns = 0
        ringStarvations = 0
        ringDrops = 0
        ringResyncs = 0
        clockCorrectionPPM = 0
        appliedChannels = []
    }
}


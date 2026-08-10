import Foundation

/// One application's saved state inside a preset.
///
/// Everything past `volume` and `isMuted` is optional on purpose. Presets
/// saved by earlier versions only ever captured level and mute, and
/// restoring one of those must not flatten an EQ the user has since dialled
/// in — a nil field means "this preset has nothing to say about that
/// setting", not "set it to the default".
public struct PresetChannel: Codable, Equatable, Sendable {
    public var volume: Float
    public var isMuted: Bool
    public var eqGains: [Float]?
    public var noiseGateThreshold: Float?
    public var compressorEnabled: Bool?
    public var routePairID: String?
    public var dawDirect: Bool?

    public init(
        volume: Float,
        isMuted: Bool,
        eqGains: [Float]? = nil,
        noiseGateThreshold: Float? = nil,
        compressorEnabled: Bool? = nil,
        routePairID: String? = nil,
        dawDirect: Bool? = nil
    ) {
        self.volume = volume
        self.isMuted = isMuted
        self.eqGains = eqGains
        self.noiseGateThreshold = noiseGateThreshold
        self.compressorEnabled = compressorEnabled
        self.routePairID = routePairID
        self.dawDirect = dawDirect
    }
}

/// A named snapshot of the whole mixer.
///
/// It used to hold two dictionaries — volumes and mutes — while the
/// Automation tab called the result a "profile" and the Focus filter
/// offered to apply one when a Focus turned on. Somebody building a
/// "Meeting" preset reasonably expects their EQ, their noise gate and their
/// routing to come with it; a preset that silently drops four of the six
/// per-app settings is the wrong shape for every place it is used.
public struct PresetModel: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var channels: [String: PresetChannel]

    public init(id: UUID = UUID(), name: String, channels: [String: PresetChannel] = [:]) {
        self.id = id
        self.name = name
        self.channels = channels
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, channels
        // Pre-migration shape.
        case appVolumes, appMutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)

        if let stored = try container.decodeIfPresent([String: PresetChannel].self, forKey: .channels) {
            channels = stored
            return
        }

        // Migrate a preset written before channels carried anything else.
        // Only volume and mute are populated, so applying it changes only
        // volume and mute — exactly what it did when it was saved.
        let volumes = try container.decodeIfPresent([String: Float].self, forKey: .appVolumes) ?? [:]
        let mutes = try container.decodeIfPresent([String: Bool].self, forKey: .appMutes) ?? [:]
        var migrated: [String: PresetChannel] = [:]
        for bundleID in Set(volumes.keys).union(mutes.keys) {
            migrated[bundleID] = PresetChannel(
                volume: volumes[bundleID] ?? 1.0,
                isMuted: mutes[bundleID] ?? false
            )
        }
        channels = migrated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(channels, forKey: .channels)
    }
}

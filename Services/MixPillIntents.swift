import AppIntents
import Foundation

/// Shortcuts, Focus filters and Spotlight support.
///
/// Everything MixPill does by hand should be doable without hands. "When I
/// join a meeting, drop Spotify to 20%" is an automation, not a feature —
/// and the right place for it is the system's own automation engine rather
/// than a rules table inside a menu bar app.
///
/// Every intent drives `ChannelConfigStore`, the same path the interface
/// uses, so an automated change persists and reaches the engine exactly
/// like a manual one.

// MARK: - App entity

/// One audio application, as Shortcuts sees it.
struct AudioAppEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Application")
    )
    static let defaultQuery = AudioAppQuery()

    /// The bundle identifier.
    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct AudioAppQuery: EntityQuery {
    @MainActor
    private var apps: [AudioAppEntity] {
        MixPillIntentBridge.shared.discoveryService?.availableApps
            .map { AudioAppEntity(id: $0.id, name: $0.name) } ?? []
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [AudioAppEntity] {
        apps.filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [AudioAppEntity] {
        apps
    }
}

// MARK: - Intents

struct SetAppVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set App Volume"
    static let description = IntentDescription(
        "Sets the volume of one application, without touching anything else."
    )

    @Parameter(title: "Application")
    var app: AudioAppEntity

    @Parameter(title: "Volume", description: "0 to 100 percent.",
               inclusiveRange: (0, 100))
    var percent: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$app) volume to \(\.$percent)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let volume = Float(max(0, min(100, percent))) / 100
        ChannelConfigStore.shared.setVolume(volume, isMuted: ChannelConfigStore.shared.isMuted(for: app.id), for: app.id)
        MixPillIntentBridge.shared.discoveryService?.refreshModelFromStore(for: app.id)
        return .result()
    }
}

struct SetAppMutedIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute or Unmute App"
    static let description = IntentDescription("Silences one application, or brings it back.")

    @Parameter(title: "Application")
    var app: AudioAppEntity

    @Parameter(title: "Muted")
    var muted: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$app) muted to \(\.$muted)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        ChannelConfigStore.shared.setVolume(
            ChannelConfigStore.shared.volume(for: app.id),
            isMuted: muted,
            for: app.id
        )
        MixPillIntentBridge.shared.discoveryService?.refreshModelFromStore(for: app.id)
        return .result()
    }
}

struct SetMasterVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set MixPill Master Volume"
    static let description = IntentDescription("Sets the level of the whole mix.")

    @Parameter(title: "Volume", description: "0 to 100 percent.",
               inclusiveRange: (0, 100))
    var percent: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set MixPill master volume to \(\.$percent)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        ChannelConfigStore.shared.setMasterVolume(Float(max(0, min(100, percent))) / 100)
        return .result()
    }
}

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply MixPill Preset"
    static let description = IntentDescription(
        "Restores every app's saved volume and mute state from one of your presets."
    )

    @Parameter(title: "Preset")
    var preset: PresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$preset)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let bridge = MixPillIntentBridge.shared
        guard let manager = bridge.presetManager,
              let discovery = bridge.discoveryService,
              let stored = manager.presets.first(where: { $0.id.uuidString == preset.id }) else {
            throw IntentError.presetMissing
        }
        manager.applyPreset(id: stored.id, to: discovery)
        return .result()
    }
}

struct SetDuckingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Smart Ducking"
    static let description = IntentDescription(
        "Turns automatic dipping of background apps during calls on or off."
    )

    @Parameter(title: "Enabled")
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set Smart Ducking to \(\.$enabled)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        ChannelConfigStore.shared.setDuckingEnabled(enabled)
        return .result()
    }
}

// MARK: - Preset entity

struct PresetEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Preset")
    )
    static let defaultQuery = PresetQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PresetQuery: EntityQuery {
    @MainActor
    private var presets: [PresetEntity] {
        MixPillIntentBridge.shared.presetManager?.presets
            .map { PresetEntity(id: $0.id.uuidString, name: $0.name) } ?? []
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [PresetEntity] {
        presets.filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        presets
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case presetMissing

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .presetMissing:
            return "That preset no longer exists. Save it again in MixPill."
        }
    }
}

// MARK: - Shortcuts

struct MixPillShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetMasterVolumeIntent(),
            phrases: ["Set \(.applicationName) volume"],
            shortTitle: "Master Volume",
            systemImageName: "speaker.wave.3"
        )
        AppShortcut(
            intent: SetDuckingIntent(),
            phrases: ["Set \(.applicationName) ducking"],
            shortTitle: "Smart Ducking",
            systemImageName: "person.wave.2"
        )
    }
}

/// The intents run outside any SwiftUI view, so they need a way to reach the
/// live managers. `AppDelegate` fills this in at launch.
@MainActor
final class MixPillIntentBridge {
    static let shared = MixPillIntentBridge()
    weak var discoveryService: AppDiscoveryService?
    weak var presetManager: PresetManager?
    private init() {}
}

// MARK: - Focus filter

/// A Focus filter, so MixPill changes with the Focus the user is already in.
///
/// This is the difference between automation the user has to set up and
/// automation that is simply part of how their Mac works. Turning on Work
/// Focus can apply a mixing preset and switch ducking on; turning it off
/// puts everything back — configured in System Settings › Focus, next to
/// every other app's filter, rather than in a rules table nobody finds.
struct MixPillFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set MixPill Profile"
    static let description = IntentDescription(
        "Applies a preset and Smart Ducking setting while this Focus is on."
    )

    @Parameter(title: "Preset")
    var preset: PresetEntity?

    @Parameter(title: "Smart Ducking")
    var ducking: Bool?

    @Parameter(title: "Master Volume", inclusiveRange: (0, 100))
    var masterPercent: Int?

    var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        if let preset { parts.append(preset.name) }
        if let ducking { parts.append(ducking ? "ducking on" : "ducking off") }
        if let masterPercent { parts.append("\(masterPercent)% master") }
        let summary = parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
        return DisplayRepresentation(title: "MixPill", subtitle: "\(summary)")
    }

    /// Focus filters are also asked to describe themselves before the user
    /// has configured anything.
    static var parameterSummary: some ParameterSummary {
        Summary {
            \.$preset
            \.$ducking
            \.$masterPercent
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let masterPercent {
            ChannelConfigStore.shared.setMasterVolume(Float(max(0, min(100, masterPercent))) / 100)
        }
        if let ducking {
            ChannelConfigStore.shared.setDuckingEnabled(ducking)
        }
        if let preset {
            let bridge = MixPillIntentBridge.shared
            if let manager = bridge.presetManager,
               let discovery = bridge.discoveryService,
               let stored = manager.presets.first(where: { $0.id.uuidString == preset.id }) {
                manager.applyPreset(id: stored.id, to: discovery)
            }
        }
        return .result()
    }
}

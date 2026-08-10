import Foundation
import Observation

@MainActor
@Observable
public final class PresetManager {
    public var presets: [PresetModel] = []

    public init() {
        loadPresets()
    }

    /// Captures every setting of every listed app, not just its level.
    @discardableResult
    public func savePreset(name: String, apps: [AudioAppModel]) -> PresetModel {
        let store = ChannelConfigStore.shared
        let preset = PresetModel(
            name: name,
            channels: store.presetSnapshot(of: apps.map(\.id))
        )
        presets.append(preset)
        persist()
        return preset
    }

    /// Replaces a preset's contents with the current mixer state, keeping
    /// its name and identity — so a rule or a Focus filter pointing at it
    /// keeps working.
    public func overwritePreset(id: UUID, with apps: [AudioAppModel]) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].channels = ChannelConfigStore.shared.presetSnapshot(of: apps.map(\.id))
        persist()
    }

    public func renamePreset(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = trimmed
        persist()
    }

    public func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    /// A name that does not collide with an existing preset.
    public func suggestedName() -> String {
        var index = presets.count + 1
        var candidate = "Preset \(index)"
        while presets.contains(where: { $0.name == candidate }) {
            index += 1
            candidate = "Preset \(index)"
        }
        return candidate
    }

    /// The preset the mixer currently matches, if any — so the Load menu
    /// can show which one is in effect instead of listing them all as
    /// equally plausible.
    public func activePresetID() -> UUID? {
        let store = ChannelConfigStore.shared
        return presets.first { !$0.channels.isEmpty && store.matchesCurrentState($0.channels) }?.id
    }

    /// Applies the preset and records the whole thing as one undoable step.
    public func applyPreset(id: UUID, to discoveryService: AppDiscoveryService) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        let store = ChannelConfigStore.shared
        let affected = Array(preset.channels.keys)
        let before = store.presetSnapshot(of: affected)
        let after = preset.channels

        store.applyPresetChannels(after)
        discoveryService.refreshModelsFromStore(for: affected)

        MixerUndoManager.shared.recordTransaction(
            label: "Apply \(preset.name)",
            undo: {
                store.applyPresetChannels(before)
                discoveryService.refreshModelsFromStore(for: affected)
            },
            redo: {
                store.applyPresetChannels(after)
                discoveryService.refreshModelsFromStore(for: affected)
            }
        )
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(presets)
            UserDefaults.standard.set(data, forKey: Constants.StorageKeys.presets)
        } catch {
            MixPillLog.error("PresetManager: failed to save presets: \(error)")
        }
    }

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: Constants.StorageKeys.presets) else { return }
        do {
            presets = try JSONDecoder().decode([PresetModel].self, from: data)
        } catch {
            MixPillLog.error("PresetManager: failed to load presets: \(error)")
        }
    }
}

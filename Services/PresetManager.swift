import Foundation
import Observation

@MainActor
@Observable
public final class PresetManager {
    public var presets: [PresetModel] = []

    public init() {
        loadPresets()
    }

    public func savePreset(name: String, apps: [AudioAppModel]) {
        var appVolumes: [String: Float] = [:]
        var appMutes: [String: Bool] = [:]

        for app in apps {
            appVolumes[app.id] = app.volume
            appMutes[app.id] = app.isMuted
        }

        let newPreset = PresetModel(name: name, appVolumes: appVolumes, appMutes: appMutes)
        presets.append(newPreset)
        persist()
    }

    public func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    /// Applies the preset to the discovered apps: persists each app's
    /// state through the channel config store (which forwards it to the
    /// MixPillCore service) and mirrors it into the visible models.
    public func applyPreset(id: UUID, to discoveryService: AppDiscoveryService) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        let store = ChannelConfigStore.shared

        for index in discoveryService.availableApps.indices {
            let bundleID = discoveryService.availableApps[index].id

            var volume = discoveryService.availableApps[index].volume
            var isMuted = discoveryService.availableApps[index].isMuted

            if let presetVolume = preset.appVolumes[bundleID] {
                volume = presetVolume
            }
            if let presetMuted = preset.appMutes[bundleID] {
                isMuted = presetMuted
            }

            discoveryService.availableApps[index].volume = volume
            discoveryService.availableApps[index].isMuted = isMuted
            store.setVolume(volume, isMuted: isMuted, for: bundleID)
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(presets)
            UserDefaults.standard.set(data, forKey: Constants.StorageKeys.presets)
        } catch {
            print("PresetManager: failed to save presets: \(error)")
        }
    }

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: Constants.StorageKeys.presets) else { return }
        do {
            presets = try JSONDecoder().decode([PresetModel].self, from: data)
        } catch {
            print("PresetManager: failed to load presets: \(error)")
        }
    }
}

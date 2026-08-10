import SwiftUI
import AVFoundation

public struct AdvancedEQView: View {
    let bundleID: String

    @Environment(CoreBridge.self) private var coreBridge

    @State private var selectedPreset: EQPreset? = EQPreset.flat
    @State private var bands: [Float] = [0, 0, 0, 0, 0]
    /// The gate threshold as the user sets it: dBFS, with the bottom of the
    /// travel meaning off. The engine still stores linear amplitude — a raw
    /// "0.07" told nobody anything about how loud the gate would open.
    @State private var gateDB: Float = Self.gateOffDB
    @State private var nightMode = false

    private static let gateOffDB: Float = -60
    private static let gateMaxDB: Float = -18

    private let bandLabels = ["100 Hz", "400 Hz", "1 kHz", "4 kHz", "10 kHz"]

    public init(bundleID: String) {
        self.bundleID = bundleID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("5-Band Equalizer")
                .font(.system(size: 15, weight: .semibold))

            // What the five numbers below actually do to the sound, drawn at
            // the rate the engine is really filtering at.
            EQCurveView(gains: bands, sampleRate: Float(coreBridge.canonicalSampleRate))

            // One-Tap Presets
            VStack(alignment: .leading, spacing: 6) {
                SettingsSectionHeader("One-Tap Presets")

                HStack(spacing: 8) {
                    ForEach(SimpleEQPreset.allCases) { preset in
                        let isActive = SimpleEQPresetManager.shared.activePreset(forBundleID: bundleID) == preset
                        Button {
                            applyOneTap(preset)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: preset.symbolName)
                                    .symbolRenderingMode(.hierarchical)
                                    .font(.system(size: 16))
                                Text(preset.rawValue)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(isActive ? Color.accentColor : nil)
                        .symbolEffect(.bounce, value: isActive)
                        .help(preset.summary)
                        .accessibilityLabel("\(preset.rawValue): \(preset.summary)")
                    }
                }
            }

            // Preset
            VStack(alignment: .leading, spacing: 6) {
                SettingsSectionHeader("Preset")

                Picker("Preset", selection: $selectedPreset.animation(Constants.Motion.spring)) {
                    Text("Custom").tag(EQPreset?.none)
                    ForEach(EQPreset.allCases) { preset in
                        Text(preset.rawValue).tag(EQPreset?.some(preset))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: selectedPreset) {
                    if let preset = selectedPreset {
                        bands = preset.gains
                        ChannelConfigStore.shared.setEQGains(preset.gains, for: bundleID)
                        disableNightModeIfNeeded()
                    }
                }
                .accessibilityLabel("Equalizer preset")
            }

            // Bands
            VStack(alignment: .leading, spacing: 6) {
                SettingsSectionHeader("Bands")

                HStack(spacing: 16) {
                    ForEach(0..<5, id: \.self) { index in
                        VStack(spacing: 4) {
                            // SwiftUI on macOS requires rotation for vertical sliders:
                            // size the track at full length first, rotate, then give
                            // the rotated control its upright layout slot.
                            Slider(value: Binding(
                                get: { bands[index] },
                                set: { newValue in
                                    var updated = bands
                                    updated[index] = newValue
                                    commitBands(updated)
                                }
                            ), in: -12.0...12.0)
                            .frame(width: 120)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 20, height: 120)
                            .accessibilityLabel("EQ band \(bandLabels[index])")
                            .accessibilityValue(String(format: "%.1f decibels", bands[index]))
                            .accessibilityHint("Adjusts the gain of the \(bandLabels[index]) band")

                            // Tapping the readout returns that band to flat.
                            // Truncating with `Int` used to report a 0.9 dB
                            // boost as "0 dB", so a band could look untouched
                            // while colouring the sound.
                            Button {
                                var updated = bands
                                updated[index] = 0
                                commitBands(updated)
                            } label: {
                                Text(String(format: "%.1f dB", bands[index]))
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(abs(bands[index]) < 0.05 ? Color.secondary : Color.accentColor)
                                    .frame(width: 48)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Reset the \(bandLabels[index]) band to 0 dB")
                            .accessibilityLabel("Reset \(bandLabels[index]) band")

                            Text(bandLabels[index])
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // Noise Gate
            VStack(alignment: .leading, spacing: 6) {
                SettingsSectionHeader("Noise Gate")

                HStack(spacing: Constants.UI.interElementSpacing) {
                    Image(systemName: "waveform")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isGateOn ? Color.accentColor : Color.secondary)
                        .frame(width: 20)
                        .animation(Constants.Motion.spring, value: isGateOn)

                    Slider(value: $gateDB, in: Self.gateOffDB...Self.gateMaxDB)
                        .accessibilityLabel("Noise gate threshold")
                        .accessibilityValue(gateLabel)
                        .accessibilityHint("Silences this app while it is quieter than the threshold")

                    Text(gateLabel)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .frame(height: Constants.UI.controlHeight)
                .onChange(of: gateDB) {
                    let threshold = isGateOn ? AudioScale.amplitude(fromDecibels: gateDB) : 0
                    ChannelConfigStore.shared.setNoiseGate(threshold: threshold, for: bundleID)
                }

                Text("Anything quieter than this is silenced — useful for a noisy stream or a game's background hiss. All the way left is off.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            let store = ChannelConfigStore.shared
            bands = store.eqGains(for: bundleID)
            selectedPreset = EQPreset.preset(matching: bands)
            nightMode = store.isNightMode(for: bundleID)

            let threshold = store.noiseGate(for: bundleID)
            gateDB = threshold > 0
                ? max(Self.gateOffDB, min(Self.gateMaxDB, AudioScale.decibels(fromAmplitude: threshold)))
                : Self.gateOffDB
        }
    }

    private var isGateOn: Bool { gateDB > Self.gateOffDB }

    private var gateLabel: String {
        isGateOn ? String(format: "%.0f dB", gateDB) : "Off"
    }

    /// One place that writes a band change, so the preset match, the store
    /// and Night Mode stay in step however the change arrived.
    private func commitBands(_ updated: [Float]) {
        bands = updated
        selectedPreset = EQPreset.preset(matching: updated)
        ChannelConfigStore.shared.setEQGains(updated, for: bundleID)
        disableNightModeIfNeeded()
    }

    // MARK: - One-Tap actions

    private func applyOneTap(_ preset: SimpleEQPreset) {
        let simpleManager = SimpleEQPresetManager.shared

        if simpleManager.activePreset(forBundleID: bundleID) == preset {
            // Tapping the active preset turns it back off.
            simpleManager.clear(forBundleID: bundleID)
            bands = EQPreset.flat.gains
            nightMode = false
        } else {
            simpleManager.apply(preset, forBundleID: bundleID)
            bands = preset.gains
            nightMode = preset == .nightMode
        }
        selectedPreset = EQPreset.preset(matching: bands)
    }

    /// Manual EQ edits imply the user is shaping the sound themselves,
    /// so Night Mode's compressor steps out of the way.
    private func disableNightModeIfNeeded() {
        guard nightMode else { return }
        nightMode = false
        ChannelConfigStore.shared.setNightMode(enabled: false, for: bundleID)
    }
}

import SwiftUI
import AVFoundation

public struct AdvancedEQView: View {
    let bundleID: String

    @State private var selectedPreset: EQPreset? = EQPreset.flat
    @State private var bands: [Float] = [0, 0, 0, 0, 0]
    @State private var noiseGate: Float = 0
    @State private var nightMode = false

    private let bandLabels = ["100 Hz", "400 Hz", "1 kHz", "4 kHz", "10 kHz"]

    public init(bundleID: String) {
        self.bundleID = bundleID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("5-Band Equalizer")
                .font(.system(size: 15, weight: .semibold))

            // What the five numbers below actually do to the sound.
            EQCurveView(gains: bands)

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
                                    bands[index] = newValue
                                    selectedPreset = EQPreset.preset(matching: bands)
                                    ChannelConfigStore.shared.setEQGains(bands, for: bundleID)
                                    disableNightModeIfNeeded()
                                }
                            ), in: -12.0...12.0)
                            .frame(width: 120)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 20, height: 120)
                            .accessibilityLabel("EQ band \(bandLabels[index])")
                            .accessibilityValue("\(Int(bands[index])) decibels")
                            .accessibilityHint("Adjusts the gain of the \(bandLabels[index]) band")

                            Text("\(Int(bands[index])) dB")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44)

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
                        .foregroundStyle(noiseGate > 0 ? Color.accentColor : Color.secondary)
                        .frame(width: 20)
                        .animation(Constants.Motion.spring, value: noiseGate > 0)

                    Slider(value: $noiseGate, in: 0.0...0.2)
                        .accessibilityLabel("Noise gate threshold")
                        .accessibilityValue(noiseGate > 0 ? String(format: "%.2f", noiseGate) : "Off")
                        .accessibilityHint("Silences audio below this level")

                    Text(noiseGate > 0 ? String(format: "%.2f", noiseGate) : "Off")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .frame(height: Constants.UI.controlHeight)
                .onChange(of: noiseGate) {
                    ChannelConfigStore.shared.setNoiseGate(threshold: noiseGate, for: bundleID)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            let store = ChannelConfigStore.shared
            bands = store.eqGains(for: bundleID)
            selectedPreset = EQPreset.preset(matching: bands)
            noiseGate = store.noiseGate(for: bundleID)
            nightMode = store.isNightMode(for: bundleID)
        }
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

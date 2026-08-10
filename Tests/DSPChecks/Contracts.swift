import Foundation

// Checks for the pure-value contracts that sit between the interface and
// the engine: the routing pair id, the DAW list, and the fader/meter
// scales. None of them touch the HAL or XPC, and every one of them has now
// been the site of a real bug — the pair-id parser crashed the audio
// service on a one-character input, and the scales were the reason the
// meter and the fader both read wrong.

@MainActor
func runContractChecks() {
    // MARK: - Routing pair ids

    print("MixEngineKey")

    do {
        check("system-default parses to the default key",
              MixEngineKey.parse(pairID: "system-default") == .systemDefault)
        check("an empty id parses to the default key",
              MixEngineKey.parse(pairID: "") == .systemDefault)

        let plain = MixEngineKey.parse(pairID: "AppleHDAEngineOutput")
        check("a bare uid is pair 0", plain.deviceUID == "AppleHDAEngineOutput" && plain.pairIndex == 0)

        let pair = MixEngineKey.parse(pairID: "Orion#7")
        check("a uid with an index parses both", pair.deviceUID == "Orion" && pair.pairIndex == 7)

        // The regression: `"#".split(separator: "#")` is empty, and indexing
        // `[0]` on it took the whole audio service down.
        let degenerate = MixEngineKey.parse(pairID: "#")
        check("a lone separator does not crash", degenerate.pairIndex == 0)
        check("a double separator does not crash", MixEngineKey.parse(pairID: "##").pairIndex == 0)

        // A device UID is an arbitrary driver-chosen string. Splitting on the
        // first "#" silently resolved the wrong device *and* the wrong pair.
        let awkward = MixEngineKey.parse(pairID: "Focusrite#1")
        check("a uid ending in #digit still resolves as uid + index",
              awkward.deviceUID == "Focusrite" && awkward.pairIndex == 1)

        let embedded = MixEngineKey.parse(pairID: "Vendor#Model#3")
        check("only the last separator is the index",
              embedded.deviceUID == "Vendor#Model" && embedded.pairIndex == 3)

        let nonNumeric = MixEngineKey.parse(pairID: "Vendor#Model")
        check("a non-numeric tail belongs to the uid",
              nonNumeric.deviceUID == "Vendor#Model" && nonNumeric.pairIndex == 0)

        // Round-tripping is what keeps a persisted route pointing at the same
        // column the interface draws.
        for id in ["system-default", "Orion", "Orion#3", "Vendor#Model#12"] {
            check("round-trip \(id)", MixEngineKey.parse(pairID: id).pairID == id)
        }
    }

    // MARK: - DAW detection

    print("DAWDetection")

    do {
        check("Logic is a DAW", DAWDetection.isDAW(bundleID: "com.apple.logic10"))
        check("Ableton is a DAW", DAWDetection.isDAW(bundleID: "com.ableton.live"))
        check("detection is case-insensitive", DAWDetection.isDAW(bundleID: "COM.APPLE.LOGIC10"))
        check("Spotify is not a DAW", !DAWDetection.isDAW(bundleID: "com.spotify.client"))
        check("a lookalike prefix is not a DAW", !DAWDetection.isDAW(bundleID: "com.example.reaperclone"))
    }

    // MARK: - Fader and meter scales

    print("AudioScale")

    do {
        check("silence is silence", AudioScale.gain(forPosition: 0) == 0)
        check("unity sits at the unity mark",
              abs(AudioScale.gain(forPosition: AudioScale.unityPosition) - 1.0) < 0.001)
        check("the top of the travel is the boost ceiling",
              abs(AudioScale.gain(forPosition: 1) - AudioScale.amplitude(fromDecibels: AudioScale.faderBoostDB)) < 0.001)
        check("boost is available above unity", AudioScale.maximumChannelGain > 1.0)

        // Position and gain have to be exact inverses, or a fader jumps the
        // moment it is redrawn from the value it just wrote.
        var invertible = true
        for step in 0...40 {
            let position = Float(step) / 40
            let round = AudioScale.position(forGain: AudioScale.gain(forPosition: position))
            if abs(round - position) > 0.002 { invertible = false }
        }
        check("fader position round-trips through gain", invertible)

        // Monotonic: no part of the travel may go backwards.
        var monotonic = true
        var previous = AudioScale.gain(forPosition: 0)
        for step in 1...100 {
            let gain = AudioScale.gain(forPosition: Float(step) / 100)
            if gain < previous { monotonic = false }
            previous = gain
        }
        check("gain rises monotonically with the fader", monotonic)

        check("no-boost faders top out at unity",
              abs(AudioScale.gain(forPosition: 1, allowBoost: false) - 1.0) < 0.001)

        // The meter bug: −18 dBFS is ordinary programme material and used to
        // fill an eighth of the bar.
        let typical = AudioScale.meterPosition(forAmplitude: AudioScale.amplitude(fromDecibels: -18))
        check("−18 dBFS lands in the middle of the meter", typical > 0.6 && typical < 0.8)
        check("full scale fills the meter",
              abs(AudioScale.meterPosition(forAmplitude: 1.0) - 1.0) < 0.001)
        check("silence empties the meter", AudioScale.meterPosition(forAmplitude: 0) == 0)
        check("the floor clamps rather than going negative",
              AudioScale.meterPosition(forAmplitude: AudioScale.amplitude(fromDecibels: -120)) == 0)

        check("a muted fader reads as minus infinity", AudioScale.faderLabel(forGain: 0) == "−∞")
        check("unity reads as 0.0 dB", AudioScale.faderLabel(forGain: 1.0) == "0.0 dB")
        check("boost is signed", AudioScale.faderLabel(forGain: 2.0).hasPrefix("+"))
    }

    // MARK: - Preset migration

    print("PresetModel")

    do {
        // A preset written before channels carried anything but level must
        // still load, and must still change only what it captured.
        let legacy = """
        {"id":"7B8E5D6C-0000-4000-8000-000000000001","name":"Old",
         "appVolumes":{"com.spotify.client":0.4},
         "appMutes":{"com.spotify.client":true}}
        """.data(using: .utf8)!

        if let preset = try? JSONDecoder().decode(PresetModel.self, from: legacy) {
            check("a legacy preset decodes", preset.name == "Old")
            let channel = preset.channels["com.spotify.client"]
            check("legacy volume survives", channel?.volume == 0.4)
            check("legacy mute survives", channel?.isMuted == true)
            check("legacy presets say nothing about EQ", channel?.eqGains == nil)
            check("legacy presets say nothing about routing", channel?.routePairID == nil)
        } else {
            check("a legacy preset decodes", false)
        }

        let modern = PresetModel(name: "New", channels: [
            "com.apple.Music": PresetChannel(
                volume: 1.5, isMuted: false, eqGains: [1, 2, 3, 4, 5],
                noiseGateThreshold: 0.01, compressorEnabled: true,
                routePairID: "Orion#2", dawDirect: false
            )
        ])
        if let data = try? JSONEncoder().encode(modern),
           let decoded = try? JSONDecoder().decode(PresetModel.self, from: data) {
            check("a full preset round-trips", decoded == modern)
        } else {
            check("a full preset round-trips", false)
        }
    }
}

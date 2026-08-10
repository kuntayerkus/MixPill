# MixPill

**Per-application volume control for macOS — live in your menu bar.**

Every app on your Mac gets its own channel strip: volume, mute, 5-band EQ,
noise gate, and a real-time level meter. Route any app to any output —
including individual channel pairs on professional interfaces — and let
Smart Ducking keep your calls clear.

Nothing to install. No audio driver, no system extension, no restart.

> macOS 15.0 (Sequoia) or later · Swift 6 · CoreAudio process taps · XPC

---

## How it works

macOS lets an app receive another app's audio through a **CoreAudio
process tap**. MixPill opens one tap per application, marked
`CATapMutedWhenTapped`, which is the detail that makes the whole product
possible: while the tap is open, macOS mutes that app's own path to the
speakers. MixPill re-plays the audio through its mixer — with your volume,
EQ, gate and ducking applied — and you hear it exactly once.

That is the entire trick, and it is why MixPill needs no virtual audio
device. Other per-app mixers ship a driver, make it your default output,
and route everything back out through it. MixPill uses a public CoreAudio
API instead: no kernel extension, no approval sheet in System Settings,
no reboot, nothing left behind if you delete the app.

```
┌──────────────── MixPill.app (menu bar UI) ─────────────────┐
│  SwiftUI MenuBarExtra · Settings · Onboarding              │
│  ChannelConfigStore — persistence, the desired state       │
│  CoreBridge — NSXPCConnection client, reconnecting         │
└──────────▲──────────────────────────────┬──────────────────┘
     apps, levels (30 Hz watched,   config snapshot,
     10 Hz closed, 1 Hz idle),      batched channel
     devices, recoveries            updates
           │                              ▼
┌──────────┴──────── MixPillCore.xpc (audio engine) ─────────┐
│  AudioProcessRegistry                                      │
│      HAL process objects → user-facing apps, helpers       │
│      folded into the app that owns them                    │
│  ProcessTapCapture                                         │
│      one muted tap + private aggregate device per app,     │
│      IOProc → meter → lock-free ring; every change to      │
│      the tap table on one serial queue                     │
│  LowLatencyMixerEngine                                     │
│      one AUHAL unit per (device, channel pair), started    │
│      on demand and released when idle; a single render     │
│      pass: ring → gate → 5×biquad → compressor → gain →    │
│      master → limiter, inline vDSP on a time-constraint    │
│      thread, allocation-free                               │
│  DeviceRegistry · DuckingController · CoreResilienceEngine │
└────────────────────────────────────────────────────────────┘
```

The audio engine is a separate XPC service. Quit or crash the menu bar
app and the music keeps playing with the last configuration it received.

## Features

- **Per-app mixing.** Independent volume, mute, solo and live meters for
  every application that plays audio. Faders travel on a dB scale with
  unity at 80% and 6 dB of boost above it, so a quietly mastered podcast
  or a too-soft conference call can be brought *up*, and the bottom of the
  travel is usable instead of being a cliff.
- **Meters that read like meters.** dBFS scale, −12 dB reference tick,
  amber and red where those levels actually are, and a held clip indicator.
  A linear-amplitude meter puts ordinary programme material at an eighth
  of the bar and never reaches its own red zone.
- **One strip per app, not per process.** A browser plays through helper
  processes; MixPill folds them into a single "Google Chrome" channel by
  resolving each audio process back to the bundle that owns it. System
  daemons never appear, and are never tapped.
- **5-band EQ and noise gate.** One-tap presets — Vocal Clarity, Bass
  Boost, Night Mode — or shape all five bands yourself, against a live
  curve drawn from the same biquad maths the engine runs. The gate
  threshold is in dBFS, because "0.07" is not a level anybody can picture.
- **Smart Ducking.** Background apps dip to 20% while someone is on a
  call. "On a call" means *a process is holding the microphone* — the HAL
  knows this for every app, so FaceTime, Meet in a browser and whatever
  ships next all work without being listed anywhere. Ducking runs in the
  core service, so it keeps working with the interface closed.
- **Routing.** Pin any app to any output device, or to a specific channel
  pair (Outputs 1-2, 3-4, …) on multi-channel interfaces — from the app's
  own row, or from the Routing tab. That tab draws a matrix while there
  are a handful of destinations and switches to one grouped menu per app
  beyond that, because a 64-channel interface contributes 32 pairs and a
  33-column grid is not a control anybody can use.
- **DAW Direct.** Logic Pro, Ableton Live, Pro Tools, Cubase, FL Studio
  and Studio One default to **completely untapped** — MixPill does not
  capture, mute or re-play them, so a DAW keeps its own monitoring
  latency, its own multi-output routing and its own buffer size, exactly
  as if MixPill were not installed. The switch is on every row, not just
  the recognised ones: anything that routes to more than one output pair
  wants it, and a DAW you deliberately want in the mix can be switched
  back on.
- **Survives the world changing.** Sleep/wake, `coreaudiod` restarts,
  device hot-plug and sample-rate changes all rebuild the engine in
  place.
- **Shortcuts and Focus filters.** Set an app's volume, mute it, apply a
  preset or toggle ducking from an App Intent — so "when I join a meeting,
  drop Spotify" is an automation the system runs, not a rules table inside
  a menu bar app.
- **Undo.** ⌘Z steps back through volume, mute, EQ and routing changes; a
  slider drag collapses into a single step rather than a hundred, and
  applying a preset is one step rather than one per app. The popover shows
  what ⌘Z will undo, so the shortcut is findable.
- **Presets that hold everything.** A preset captures each app's volume,
  mute, EQ, noise gate, Night Mode, output and DAW Direct state — not just
  its level. Name them, overwrite them, and see which one the mixer
  currently matches. Presets written by older versions still load and
  still change only what they captured.
- **Nothing running when nothing is playing.** The output unit is released
  after the last channel goes quiet, so the audio device can idle instead
  of being held awake for as long as MixPill is installed.
- **Web audio.** Safari plays through WebKit's shared GPU process, which
  no public API can attribute to a specific app. Rather than leave the
  Mac's default browser uncontrollable, that audio gets its own channel,
  named for Safari when Safari is running and "Web Content" when it is
  not. It appears only while it is playing.
- **Keyboard and pointer both work.** The popover opens focused on search;
  Return moves into the list, ↑↓ walk it, ←→ ride the fader, `M` mutes and
  `S` solos. Reduce Motion is honoured throughout.
- **Privacy first.** Entirely on-device. No account, no analytics. The
  only request that ever leaves your Mac is the check for an update.
- **English and Turkish.** Every string lives in the catalog, so a third
  language is a translation pass rather than a code change.

## Latency

Mixing runs in a single CoreAudio render callback: lock-free ring read →
noise gate → 5-band biquad EQ → compressor → channel gain → master gain →
brickwall limiter, all inline vDSP on a Mach time-constraint thread.
Playback runs at 256 frames (≈5 ms), or 128 (≈3 ms) in Ultra-Low Latency.

Nothing in that pass allocates. The parameter block the render thread
reads is plain old data — the five biquad sections are inline SIMD storage
rather than nested arrays — so a parameter change costs a `memcpy` and a
`vDSP_biquad_SetCoefficientsSingle`, never a `malloc` behind a deadline.

Capture is deliberately slower: 1024 frames (≈21 ms), dropping to 256 in
Ultra-Low Latency. The ring absorbs that delay, while the deadline
pressure that makes CoreAudio skip a cycle scales with how often the cycle
runs. Measured over four minutes with three apps tapped on a 64-channel
interface, a 256-frame capture block produced 13 dropouts and a
1024-frame block produced none. Ultra-Low Latency hands that headroom back
to anyone monitoring live audio.

## Permissions

**None, for mixing.** A signed app may open process taps on specific
processes without a TCC prompt, so MixPill starts working the moment you
launch it. No Screen Recording, no microphone, no approval sheet.

Accessibility is requested only if you turn on global hotkeys (⌥ Scroll to
adjust the frontmost app's volume, ⌘⌥M to mute it).

The app deliberately does not try to predict this. Capture health is
reported by the core from whether `AudioHardwareCreateProcessTap` actually
succeeded, and the UI shows a banner only when a tap really fails, quoting
the OSStatus. An earlier build inferred readiness from the microphone TCC
status instead and put a permission wall in front of a mixer that was
already running — while pointing at a Settings pane MixPill was not listed
in. Observed state only.

## Requirements

- macOS 15.0 or later
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build and run

```bash
git clone https://github.com/kuntayerkus/MixPill.git
cd MixPill
xcodegen generate
open MixPill.xcodeproj
```

Then run from Xcode (⌘R). `project.yml` is the single source of truth —
the Xcode project is generated and should never be edited by hand. Two
targets are produced:

| Target | Type | Role |
|---|---|---|
| `MixPill` | Menu bar app | SwiftUI status, commands, settings |
| `MixPillCore` | Bundled XPC service | Capture, DSP, mixing, routing, resilience |

## Project layout

| Layer | Files |
|---|---|
| Shared contract | `Shared/` — XPC protocols, DTOs, identifiers, `MixEngineKey` |
| Shared by both targets | `Utilities/` — `AudioScale` (every dB/fader/meter conversion), constants, locking |
| UI entry | `App/MixPillApp.swift`, `App/AppDelegate.swift` |
| UI ↔ core | `App/CoreBridge.swift`, `App/ChannelConfigStore.swift` |
| UI models | `Models/` |
| UI services | `Services/` — permissions, presets, automation, hotkeys, gestures, focus shield |
| Core entry | `Core/main.swift`, `Core/MixPillCoreService.swift` |
| Core capture | `Core/AudioProcessRegistry.swift`, `Core/ProcessTapCapture.swift` |
| Core audio | `Core/LowLatencyMixerEngine.swift`, `Core/ChannelDSP.swift`, `Core/RingBufferManager.swift`, `Core/AudioResamplerService.swift` |
| Core system | `Core/DeviceRegistry.swift`, `Core/DuckingController.swift`, `Core/CoreResilienceEngine.swift`, `Core/RealtimeSupport.swift` |
| Assets | `Resources/Assets.xcassets`, generated by `Tools/GenerateAppIcon` |

## Development

**Checks.** The ring buffer and the channel DSP are plain Swift with no
HAL or XPC dependency, so they run standalone:

```bash
Tests/DSPChecks/run.sh           # 67 checks
Tests/DSPChecks/run.sh --guard   # …under libgmalloc
```

They cover the ring buffer, the filter chain, the routing pair id
(`MixEngineKey`), the fader and meter scales, and preset migration —
everything that is pure value logic, which is most of what has ever been
wrong.

Run the guard-malloc variant before shipping changes to the audio path.
Three of the bugs these checks were written for were heap overruns,
including a `vDSP_biquad` delay buffer sized `2×sections` when the
documented requirement is `2×sections + 2`. An overrun does not reliably
crash on its own.

**Watching the engine.** MixPillCore is launched by launchd, so its
stdout goes nowhere. Diagnostics go to the unified log:

```bash
log stream --predicate 'subsystem == "com.mixpill.core"' --level debug
```

**Strings.** Every user-facing string lives in
`Resources/Localizable.xcstrings`. Xcode syncs it when you build in the
IDE; from a terminal, run `Tools/sync-strings.sh`. English and Turkish
ship today; adding a third is a translation pass rather than a refactor.

**Watching the interface.** The app target logs to its own subsystem:

```bash
log stream --predicate 'subsystem == "com.mixpill.app"' --level debug
```

**Releasing.** `Tools/release.sh 3.2.0` stamps the version into
`project.yml`, archives, signs with Developer ID, notarizes, staples, runs
Gatekeeper's own assessment, produces a signed DMG **and writes a signed
`appcast.xml`**, then prints the commands that publish it. See
[Releasing](#releasing) below for what has to exist first.

**Icon.** `Tools/GenerateAppIcon` renders the full macOS size ladder and
the menu bar template glyph from code:

```bash
swift Tools/GenerateAppIcon/main.swift \
    Resources/Assets.xcassets/AppIcon.appiconset \
    Resources/Assets.xcassets/MenuBarIcon.imageset
```

## Releasing

MixPill is distributed directly: Developer ID signing plus notarization,
hardened runtime on, App Sandbox off. Both entitlements files are
deliberately empty and say why — the app needs no entitlement, only the
Accessibility grant, and only if you turn hotkeys on. Sandboxing would
mean reinstating `com.apple.security.inherit` in the core's entitlements;
the two files have to agree.

Updates go through [Sparkle](https://sparkle-project.org). The feed lives
in this repository at `appcast.xml`, and the disk images are attached to
GitHub Releases, so publishing needs no web hosting.

**One-time setup**

| What | How |
|---|---|
| Developer ID Application certificate | developer.apple.com → Certificates → **+** → Developer ID Application. Needs a paid Apple Developer Program membership; a free account cannot issue one. |
| Notarization credentials | `xcrun notarytool store-credentials MixPillNotary --apple-id <you> --team-id CL4KZ4JZDQ --password <app-specific password>` |
| Sparkle signing key | `.spm/artifacts/sparkle/Sparkle/bin/generate_keys`. The public half goes in `Resources/Info.plist` as `SUPublicEDKey`; the private half stays in your keychain. **Back it up** — losing it means never being able to update an existing install again. |

**Each release**

```bash
Tools/release.sh 3.2.0
```

It stamps the version and bumps the build number in `project.yml`,
archives, signs, notarizes, staples, checks Gatekeeper's verdict, builds a
signed DMG and regenerates `appcast.xml`, then prints the
`gh release create` and `git push` commands to finish the job.

**Pushing `appcast.xml` to `main` is what makes the update live.** The
feed URL points into this repository, so a release whose appcast never
lands is a release no installed copy will ever be offered — which is
exactly what happened to 3.1.0. The script now generates and verifies the
feed rather than leaving it as a printed reminder.

One trap worth knowing, because it fails silently: `generate_appcast`
signs an update only if the archived app's `SUPublicEDKey` matches the
private key in your keychain. If it does not, it writes an unsigned entry
without complaining, and Sparkle then rejects that update on every
machine. `release.sh` compares the two and refuses to continue, but if you
ever run the tool by hand, check the output contains
`sparkle:edSignature`.

## Known limitations

- Audio reaching the speakers through a shared system process cannot be
  attributed to the app that produced it. WebKit's GPU process is handled
  explicitly (see above); any other such process is left alone rather than
  guessed at.
- An app tapped by MixPill is muted at source, so an application routing
  to several output pairs at once has the pairs MixPill does not replay
  silenced. Known DAWs are excluded automatically; anything else with
  multi-output routing can be switched to DAW Direct from its own row.
  A channel MixPill is not capturing says so and disables its controls,
  rather than offering a fader that moves without changing the sound.
- Menu-bar-only applications (`LSUIElement`) are not listed. Discovery
  keeps to processes owned by an app with a Dock presence, which is what
  keeps daemons out of the mixer — muting `systemsoundserverd` would
  silence system alerts — but it excludes a menu bar music player too.
- While a tap is open the app is muted at the system level, which means
  its audio is subject to MixPill being alive to re-play it. The core
  service is deliberately separate from the UI for exactly this reason,
  but a crashed core is silence until it restarts.
- Global hotkeys and quick gestures require Accessibility trust.

## License

All rights reserved.

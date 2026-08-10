# Open work on the audio path

Everything here came out of the 2026-08-10 session that chased the constant
clicking during video playback. The clicking itself is fixed and measured;
these are the things that are *not* finished, roughly in the order they are
worth doing. Each one records what is already known so the next session does
not re-derive it.

---

## 1. Faders are overwritten ~60 ms after every move — **blocking, unfinished**

A fader move reaches the engine and is then reverted to unity, so the
control appears dead.

```
21:23:15.271  Applied com.google.Chrome: gain 0.088  (-21.1 dB)   ← the drag
21:23:15.355  Applied com.google.Chrome: gain 1.0    (0.0 dB)     ← 84 ms later
21:23:15.751  Applied com.google.Chrome: gain 0.0416 (-27.6 dB)   ← drag again
21:23:15.816  Applied com.google.Chrome: gain 1.0    (0.0 dB)     ← reverted again
```

Ruled out already:

- **Not a stale store.** `ChannelConfigStore` keeps values in memory and only
  *persists* on a 250 ms debounce; every getter reads the in-memory
  dictionary, so `channels(for:)` returns the fresh value.
- **Not the undo manager.** `MixerUndoManager.record` only coalesces entries;
  it never invokes an `undo` closure.
- **Not a duplicate process.** One UI, one core, confirmed by `pgrep`.

**Next step, already prepared.** Every applied channel now logs which
message carried it — `via channel` (a single row), `via table` (the bulk
push after a discovery event), `via configuration` (a full snapshot) or
`via default` (`ensureStrip` seeding a strip at 1.0). One fader move on the
current build names the culprit:

```
/usr/bin/log stream --predicate 'subsystem == "com.mixpill.core"' --info --debug --style compact | grep Applied
```

Prime suspect on the evidence so far is the bulk push: `AppDiscoveryService`
`handleCoreApps` calls `bridge.pushChannels(store.channels(for:))` on every
app-list event, and the core re-pushes the app list whenever capture state
changes — so a fader move that touches capture state could echo back as a
full table write.

---

## 2. Adaptive jitter buffer — the remaining dropouts

Under 24 CPU spinners the rate loop holds, but the coarse jump path fires
**3–16 times per 5 s**. That is not drift: it is the render thread being
descheduled for longer than the buffer holds (>85 ms), so there is genuinely
nothing to play.

The target delay is currently fixed at `producerBlock + max(consumerBlock,
producerBlock/2)` — about 32 ms. The standard answer is what WebRTC's NetEQ
does: **grow the target when dropouts happen, decay it slowly while the
stream stays clean**. A machine under load then buys safety with latency and
gives it back when it is idle, instead of being tuned for one of the two.

Sketch: an `extraMarginFrames` added to `targetFrames`, raised by one
producer block on each underrun/starvation, capped at a few blocks, decayed
after N seconds of clean reads. The rate loop already walks occupancy to
whatever the setpoint says, so nothing else has to change.

---

## 3. Tap creation is serialised behind one slow tap

`ProcessTapCapture.lifecycleQueue` is serial, so one application's tap start
blocks every other. Measured `tap work waited 235.61 s for the lifecycle
queue` while a single tap sat in the HAL for 104 s.

Harmless when taps open in 0.03 s, which is the normal case. Worth making
concurrent per-application anyway — but note the serial queue was introduced
deliberately to fix a real race (two overlapping syncs both deciding the
same app needed a tap, leaving an orphaned IOProc that muted the app for
good). Any change here has to keep that invariant.

---

## 4. `coreaudiod` stalls on this machine — environmental, not ours

Opening one tap intermittently takes **120 s**, in four clean 30-second
steps (the HAL's client-to-daemon timeout), one per property call on the new
aggregate. Proven not to be MixPill: the same sequence from a standalone
command-line tool, run at the same moment, took 101 s, and the very next tap
MixPill opened took 0.03 s.

This Mac carries seven third-party CoreAudio drivers (SoundID Reference,
Sonarworks Systemwide, Pro Tools Audio Bridge, Parrot, Kemper Profiler, ACE,
RDUSB0299) and creating a private aggregate makes `coreaudiod` consult every
plug-in. Nothing to fix in the app; worth remembering when a measurement on
this machine looks impossible.

Read the `s in the HAL` figure in the tap log line first: large there is
their audio stack, large in `waited` is ours.

---

## 5. Interpolator quality — upgrade path, not a defect

The rate converter uses 4-point cubic Hermite: the quality/cost knee for
polynomial interpolators on audio that is not oversampled. A dedicated ASRC
part uses a polyphase FIR and reaches ~130 dB.

At the ratios this loop actually runs (settled at +9 ppm on the reference
rig) the interpolation error is far below the splices it replaced, and the
calibration tone reads back at exactly −20.00 dBFS. Worth revisiting only if
someone measures a problem, not on principle.

---

## 6. Diagnostics added this session — keep or prune

All of these earned their place by answering something that was otherwise
unanswerable, but they should be reviewed once the questions above close:

- `Applied …, via <source>` — which message set a channel value.
- `… s in the HAL (tap …, aggregate …, start …)` — where tap-open time goes.
- `tap work waited … s for the lifecycle queue` — queue starvation vs HAL.
- `AudioProcessRegistry: N objects resolve to M applications: …` — separates
  "cannot see your app" from "sees it and cannot tap it".
- `rate ±N ppm` in the health line, and **Clock Correction** in Diagnostics.

---

## Reference numbers from the session

| | value |
|---|---|
| Measured clock drift, tap vs output | **+9.8 ppm** (48000.014 vs 47999.542 Hz) |
| Rate loop settles at | **+9 ppm**, occupancy on setpoint |
| Startup transient | ~200 ppm (≈3 cents), seconds |
| Calibration tone through the whole chain | **−20.00 dBFS, 0 gaps, 0 clicks** |
| Clean run | no health line at all |
| 3 min at full CPU load | 0 drops, 0 starvations, 1 underrun |
| Before any of this | ring pinned 7168–7936/8192, a drop every ~3 s, 160 ms latency |

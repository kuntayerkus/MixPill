# loadcheck — measuring what actually comes out

`Tests/DSPChecks` proves the value logic. This proves the *sound*: it taps
a running process and measures the signal it really emits, so a claim like
"the dropouts are fixed" is a number rather than an impression.

Everything here is standalone — no Xcode target, no dependency on the app
building. Compile with `swiftc -O`.

## The instrument

    swiftc -O -o tapmeter tapmeter.swift
    ./tapmeter <bundle-id> <seconds> [label] [warmup-seconds]

Creates an **unmuted** private process tap on the target (it observes; it
must not change what the speakers do) and reports RMS/peak, silence gaps,
waveform discontinuities, late capture blocks and CoreAudio overloads as
JSON.

Three details that make the numbers trustworthy:

- **Mixdown compensation.** A stereo-mixdown tap on a wide interface
  attenuates by `channels / 2` — ×32 on a 64-channel desk. The instrument
  multiplies it back, and the calibration below is what proves it right.
- **Warmup.** Creating the tap's own aggregate device is itself a HAL
  topology change, and the thing being measured reacts to those. The first
  few seconds are excluded so the instrument's footprint stays outside the
  measurement window. Without it every run reported one phantom click.
- **Gap arming.** Silence is only a dropout once signal has been seen;
  otherwise "nothing is playing yet" reads as a fault. A run that never saw
  signal is reported as `"note": "no signal seen"` rather than as zero gaps.

## Calibration

Generate a source of known level and check the instrument reads it back:

    python3 - <<'PY'
    import wave, math, struct
    fs, secs, f = 48000, 120, 1000.0
    amp = (10 ** (-20.0 / 20)) * math.sqrt(2)      # −20 dBFS RMS sine
    frames = bytearray()
    for n in range(fs * secs):
        v = int(amp * math.sin(2 * math.pi * f * n / fs) * 32767)
        frames += struct.pack('<hh', v, v)
    with wave.open('tone.wav', 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(fs)
        w.writeframes(bytes(frames))
    PY

Play it in QuickTime — **not** `afplay`: discovery only lists applications
with a Dock presence, so a command-line player is never tapped and never
enters the mixer at all. Then:

    ./tapmeter com.apple.QuickTimePlayerX 15 calibration

`rmsDBFS` must come back at −20.0. Measured 2026-08-10: **−20.00**.

## The drift probe

    swiftc -O -o clockdrift clockdrift.swift
    ./clockdrift <bundle-id> <seconds>

Runs the two clocks MixPill's pipeline straddles side by side against the
same wall clock — a process tap's aggregate device (the producer) and an
AUHAL output unit on the default device (the consumer) — and divides each
one's delivered frames by the elapsed time.

This is the instrument that turned "the clicking comes back eventually"
into a number. Measured 2026-08-10 on the Orion 32+:

    "producerRateHz" : 48000.014
    "consumerRateHz" : 47999.542
    "driftPPM"       : 9.84
    "ringDriftFramesPerHour" : 1701

Two independent clocks with no rate conversion between them: the buffer in
the middle must eventually either overflow or empty, whatever its size, so
something has to steer it. Read `RingBufferManager` for what does.

Note the sign is a property of the *hardware pairing*, not of MixPill. On
another Mac the producer may be the slower one, and the failure then
arrives as a dropout rather than a discarded block.

## The load

    ./load.sh start    # one CPU spinner per core + 4 disk writers
    ./load.sh stop     # always run this

## The four scenarios

Control first, always. The point of A/B is to prove the load alone is
harmless, so that anything C/D shows belongs to MixPill.

| | source | MixPill | tap |
|---|---|---|---|
| A | QuickTime | not running | `com.apple.QuickTimePlayerX` |
| B | QuickTime + load | not running | `com.apple.QuickTimePlayerX` |
| C | QuickTime | running | `com.mixpill.core` |
| D | QuickTime + load | running | `com.mixpill.core` |

Read MixPill's own account of the same window alongside it:

    /usr/bin/log show --start "<ts>" --predicate 'subsystem == "com.mixpill.core"' \
        --info --debug --style compact | grep -E "Health|frames buffered|Overload"

`devices.swift` prints device UID → name, which is how an overload line
naming a bare UID becomes "the monitor's HDMI output".

## What the environment has to be

Every tapped application is a variable. A run with a DAW open measures the
DAW as much as MixPill: on 2026-08-10 a mid-run Premiere Pro launch put a
7.4-second silence into an otherwise idle scenario. Close everything that
makes sound, and check the tap list in the log before trusting a number.

import Foundation
import AVFoundation
import Accelerate
import Synchronization

/// Lock-free single-producer/single-consumer ring buffer for planar Float32
/// PCM audio, sized in frames per channel.
///
/// Producer: the capture/resampler path (resampled canonical buffers).
/// Consumer: the real-time render callback of the owning app's channel
/// strip.
///
/// Sizing: the ring is a jitter guard between producer and consumer, not a
/// storage tank, and because it drops oldest rather than blocking, its
/// steady-state occupancy is set by the producer's block size — not by its
/// capacity. Capacity therefore only needs to comfortably exceed one
/// capture block; anything less discards part of every buffer written.
/// See `LowLatencyMixerEngine.minimumRingFrames` for the chosen floor.
///
/// Occupancy: capacity alone guards nothing, because the consumer drains
/// whatever it finds on every callback. With a 1024-frame producer and a
/// 256-frame consumer on the same clock, occupancy falls to zero once per
/// producer block no matter how large the ring is, so a producer block that
/// arrives a moment late lands *after* the read that needed it. That is one
/// hole per hiccup at idle, and under CPU load — where the capture thread
/// is descheduled for longer than a block — it is continuous silence.
///
/// So the ring keeps a **target occupancy** instead. It stays quiet until
/// it holds one producer block plus one consumer block, and only then
/// starts handing audio out; steady state then oscillates between one and
/// two consumer blocks of slack rather than between zero and one producer
/// block. The cushion is learned from the traffic (`producerBlockFrames`)
/// rather than configured, so ultra-low-latency mode — where the producer
/// block is 256 frames, not 1024 — pays a proportionally smaller latency
/// for it. Running dry re-arms the gate: one deliberate silence while the
/// cushion refills, instead of a chopped block every callback thereafter.
///
/// **A target is not a target unless something steers back to it.** The
/// cushion above only sets a floor; on its own, occupancy is a ratchet that
/// can climb but never fall, and two independent mechanisms push it up:
///
/// - *Stalls.* Producer and consumer are separate HAL clients. Anything
///   that pauses the output IO cycle for longer than a block — another
///   application opening the device, an aggregate appearing, a rebuild, a
///   wake — leaves the tap writing into a ring nobody is draining. At
///   48 kHz an 8192-frame ring fills in 170 ms, and there it stayed:
///   measured 2026-08-10 at 7168–7936 of 8192 with a target of 1280,
///   permanently, which is 160 ms of latency and a drop every ~3 seconds
///   for as long as the app kept playing. Each of those drops discards the
///   oldest frames mid-waveform — the audible click this whole comment is
///   about.
/// - *Clock drift.* The tap's aggregate and the output device are two
///   clocks, and no rate conversion sits between them. Measured on this
///   rig: producer 48000.014 Hz, consumer 47999.542 Hz — **+9.8 ppm**, or
///   1701 frames per hour into a ring that has nowhere to put them. The
///   sign is a property of the hardware pairing, so the other direction
///   (a ring that slowly empties into a dropout) is just as likely.
///
/// They are answered separately, because they are different problems and
/// the industry has long since settled which tool each one takes.
///
/// **Drift is absorbed by resampling.** `read` is a rate converter whose
/// ratio is the output of a PI loop closed on the ring's own occupancy —
/// the same shape as the "Drift Correction" checkbox on a CoreAudio
/// aggregate device (Apple's own docs call it resampling), as a USB Audio
/// Class 2 asynchronous endpoint's feedback loop, and as any dedicated ASRC
/// part. The correction it settles on *is* the ratio between the two
/// clocks: given the +9.8 ppm above it converges to +9 ppm and holds there,
/// with the error spread across every sample instead of collected up and
/// paid off in one audible splice. Splices are what systems do when they
/// cannot resample.
///
/// **A stall is not drift, and gets jumped.** The loop bends the stream by
/// at most a fraction of a percent, so a hundred milliseconds of backlog
/// would take a minute to walk off, all of it audibly late. A backlog past
/// four producer blocks is treated as a discontinuity in the stream: the
/// read position jumps onto the target in one step, crossfaded across a
/// block. That is the one place a splice is the right answer, and it is
/// reported separately (`resyncs`) so its rate can be watched.
///
/// Design rules that keep the render path real-time safe:
/// - Counters are monotonic; power-of-two capacity turns wrap-around into a
///   bitmask, so there is no modulo division on the hot path.
/// - The consumer only ever advances `tail`. The producer advances `head`
///   and may advance `tail` through a compare-exchange loop (drop-oldest)
///   when an incoming block would overflow the buffer.
/// - Copies touch at most two contiguous segments per channel; underrun
///   silence is filled with a single-pass vDSP clear.
public final class RingBufferManager: @unchecked Sendable {
    public let channelCount: Int
    public let capacity: Int

    private let mask: Int
    private let storage: [UnsafeMutablePointer<Float>]
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    /// Diagnostics.
    ///
    /// An underrun here means a **partial** read: the ring had audio but
    /// not enough, so the block was completed with silence. That is the
    /// audible one — a gap spliced into a running signal.
    ///
    /// A starvation is an *empty* read — the dominant failure under load,
    /// and the one the counters used to miss entirely. It could not simply
    /// be counted, because an app that is not playing has an empty ring by
    /// definition and reading silence from it is correct, not a fault;
    /// counting those buried the real signal under one hit per render
    /// callback per idle app. The prime gate is what separates the two: an
    /// empty read only counts once the ring has been streaming, so a
    /// dropout registers and an idle channel stays silent in every sense.
    ///
    /// A drop is a write that overwrote frames the consumer never read.
    ///
    /// A resync is the corrective one: the read position was moved back
    /// onto the target because the occupancy average had drifted out of
    /// band. It is not a fault — it is the mechanism working — but its rate
    /// is worth watching, because a resync every few seconds means
    /// something upstream is stalling repeatedly rather than drifting.
    private let underrunCount = Atomic<Int>(0)
    private let starvationCount = Atomic<Int>(0)
    private let dropCount = Atomic<Int>(0)
    private let resyncCount = Atomic<Int>(0)

    public var underruns: Int { underrunCount.load(ordering: .relaxed) }
    public var starvations: Int { starvationCount.load(ordering: .relaxed) }
    public var drops: Int { dropCount.load(ordering: .relaxed) }
    public var resyncs: Int { resyncCount.load(ordering: .relaxed) }

    /// Whether the ring is currently handing audio out (`true`) or filling
    /// its cushion (`false`). Consumer-owned; the producer never writes it.
    private let primed = Atomic<Bool>(false)
    /// Largest block the producer has delivered, which is how the target
    /// occupancy sizes itself without being told. Cleared by `reset()` so a
    /// graph rebuild — the one moment the capture block size can change —
    /// re-learns it rather than carrying the old value forward.
    private let producerBlockFrames = Atomic<Int>(0)

    public var isPrimed: Bool { primed.load(ordering: .relaxed) }

    /// Occupancy the ring fills to before it starts (or restarts) playing
    /// out, and the occupancy a resync restores: one whole producer block,
    /// which is what the consumer eats between deliveries, plus a margin
    /// that survives a delivery arriving late.
    ///
    /// The margin used to be one consumer block — 5.3 ms at 256 frames, and
    /// the *only* thing standing between an ordinary scheduling hiccup on
    /// the capture thread and an audible hole. It scales with the producer
    /// now, because that is what sets how late "late" can be: a 1024-frame
    /// capture block means a block can be a whole 21 ms overdue. Half a
    /// producer block costs about 5 ms of extra delay and doubles the
    /// tolerance, which is the right side of that trade for everything
    /// except live monitoring — where the producer block is 256 frames
    /// anyway and the margin shrinks with it.
    ///
    /// Capped at half the ring. The cap is what keeps the resync arithmetic
    /// inside the buffer: re-anchoring reads one target *plus* one consumer
    /// block back from the writer, and that has to remain a position the
    /// producer has not yet overwritten.
    public func targetFrames(consumerFrames: Int) -> Int {
        min(learnedProducerBlock + jitterMargin(consumerFrames: consumerFrames), capacity / 2)
    }

    private func jitterMargin(consumerFrames: Int) -> Int {
        max(consumerFrames, learnedProducerBlock / 2)
    }

    private var learnedProducerBlock: Int {
        min(producerBlockFrames.load(ordering: .relaxed), capacity / 2)
    }

    // MARK: - Rate control (consumer/render thread only)

    /// Fractional read position past `tail`, in samples.
    ///
    /// The pipeline straddles two clocks — the tap's aggregate device and
    /// the output device — and nothing between them converts rates. That is
    /// not a tuning problem, it is a structural one: measured on this rig
    /// the producer runs at 48000.014 Hz and the consumer at 47999.542 Hz,
    /// and a buffer fed by one and drained by the other must eventually
    /// overflow or empty no matter how large it is.
    ///
    /// Every audio system that spans two clocks answers this the same way.
    /// A CoreAudio aggregate device nominates one member as the clock and
    /// *resamples* the others — the checkbox in Audio MIDI Setup is
    /// literally labelled "Drift Correction", and Apple's own docs call the
    /// mechanism resampling. A USB Audio Class 2 asynchronous endpoint
    /// reports its true rate on a feedback endpoint so the host can adjust
    /// its send rate continuously. Dedicated ASRC blocks steer the ratio
    /// from a buffer watermark through a PI loop. What none of them do is
    /// wait for the buffer to reach a wall and then splice — dropping or
    /// repeating a chunk is the fallback for systems that *cannot*
    /// resample, and it is audible precisely because it is discrete.
    ///
    /// So this is a resampler whose ratio is a control signal. The
    /// correction it needs in steady state is around ten parts per million;
    /// spread continuously across every sample it is inaudible, where the
    /// same error collected up and paid off in one 5 ms splice was not.
    private var readPhase: Double = 0

    /// Input frames consumed per output frame. 1.0 is a matched pair of
    /// clocks; the loop below keeps it within a fraction of a percent.
    private var rateRatio: Double = 1
    /// Low-passed occupancy, in frames — the process variable.
    private var smoothedOccupancy: Double = 0
    /// Integral term, in units of proportional error × reads.
    private var rateIntegral: Double = 0
    private var controllerPrimed = false

    /// Smoothing on the occupancy measurement, per read.
    ///
    /// Occupancy is a sawtooth by construction: the producer adds a whole
    /// block at once and the consumer takes a fraction of one at a time. The
    /// controller must see its *mean*, not its teeth, so this averages over
    /// roughly 128 reads — about 0.7 s at 256 frames and 48 kHz, many
    /// producer periods, and still far faster than any drift.
    private static let occupancySmoothing = 1.0 / 512.0

    /// Proportional and integral gains, in rate correction per frame of
    /// occupancy error.
    ///
    /// The integral term is the one that matters. A constant clock offset —
    /// 9.8 ppm here — leaves a standing error under proportional control
    /// forever; only the integral walks the ratio onto the true ratio
    /// between the two clocks and holds it there with no error at all. The
    /// proportional term is there for damping.
    private static let proportionalGain = 0.000003
    private static let integralGain = 0.00000000058

    /// Most the ratio may move per read.
    ///
    /// This is not tuning, it is a guarantee. Everything else in the loop
    /// runs on a measurement — occupancy — that is a sawtooth with a period
    /// of a few reads, and any ripple that survives into the ratio becomes
    /// pitch modulation at tens of hertz, which is roughness rather than
    /// drift correction. Bounding how fast the ratio can move puts a hard
    /// ceiling on that frequency content regardless of gains, measurement
    /// noise, or what the producer does. One part per million per read is
    /// about 190 ppm per second: fast enough to swallow a 1000 ppm error in
    /// five seconds, far too slow to modulate anything audible.
    private static let maximumRatioSlewPerRead = 0.00002

    /// Ceiling on the rate correction.
    ///
    /// Real clock pairs differ by tens of parts per million — the pair
    /// measured here by ten. This clamp is two thousand, so it is not a
    /// working limit but a guard against the loop chasing something a
    /// resampler was never going to fix, and it caps the worst audible
    /// excursion at about thirty cents. Anything needing more than this is
    /// a discontinuity, and the jump above is what answers those.
    private static let maximumRateCorrection = 0.003

    /// Resets the loop. Used wherever the stream restarts, so a ratio
    /// learned from the old one cannot be applied to the new.
    private func resetController() {
        readPhase = 0
        rateRatio = 1
        smoothedOccupancy = 0
        rateIntegral = 0
        controllerPrimed = false
    }

    /// The occupancy the loop actually steers, which is **not** `target`.
    ///
    /// Occupancy is a sawtooth: it is `target` the instant a producer block
    /// lands and falls by a whole block before the next one does, so its
    /// average sits half a block lower. Aiming the loop at the peak would
    /// have it forever trying to raise an average that is behaving exactly
    /// as designed — measured as a 600 ppm excursion every time a stream
    /// started, spent correcting nothing. The peak is what the prime gate
    /// establishes and what latency is quoted from; the mean is what a
    /// controller can hold.
    private func setpoint(target: Int) -> Double {
        Double(target) - Double(learnedProducerBlock) / 2
    }

    /// Advances the loop by one read and returns the ratio to use.
    private func updateRate(occupancy: Int, target: Int) -> Double {
        let aim = setpoint(target: target)
        if controllerPrimed {
            smoothedOccupancy += (Double(occupancy) - smoothedOccupancy) * Self.occupancySmoothing
        } else {
            // Seeded at the setpoint rather than at whatever this first read
            // happened to see, so the loop starts with nothing to correct
            // and the average settles onto it from the right side.
            smoothedOccupancy = aim
            controllerPrimed = true
        }

        // Error in frames, positive when the pipeline is carrying too much.
        // A surplus is drained by consuming *more* input per output frame,
        // so the correction shares its sign.
        let error = smoothedOccupancy - aim
        rateIntegral += error

        // Anti-windup: the integral may never ask for more than the clamp
        // can deliver, or a long stall leaves it pinned and the loop
        // overshoots for just as long on the way back.
        let integralLimit = Self.maximumRateCorrection / Self.integralGain
        rateIntegral = min(max(rateIntegral, -integralLimit), integralLimit)

        let demand = Self.proportionalGain * error + Self.integralGain * rateIntegral
        let clamped = min(max(demand, -Self.maximumRateCorrection), Self.maximumRateCorrection)
        let target = 1 + clamped
        let step = min(max(target - rateRatio, -Self.maximumRatioSlewPerRead), Self.maximumRatioSlewPerRead)
        rateRatio += step
        return rateRatio
    }

    /// Four-point cubic Hermite (Catmull-Rom) interpolation.
    ///
    /// The quality/cost knee for polynomial interpolators on audio that is
    /// not oversampled: it costs a handful of multiplies per sample and is
    /// far cleaner than linear, whose response sags audibly in the top
    /// octave as the fractional phase sweeps. A polyphase FIR would be
    /// cleaner still — that is what a dedicated ASRC part uses to reach
    /// 130 dB — and is the upgrade path if this is ever measured to matter.
    /// At the ratios this loop actually runs, the interpolation error sits
    /// far below the splices it replaces.
    @inline(__always)
    private static func hermite(_ x0: Float, _ x1: Float, _ x2: Float, _ x3: Float, _ f: Float) -> Float {
        let c0 = x1
        let c1 = 0.5 * (x2 - x0)
        let c2 = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3
        let c3 = 0.5 * (x3 - x0) + 1.5 * (x1 - x2)
        return ((c3 * f + c2) * f + c1) * f + c0
    }

    /// Render scratch, one channel at a time. `inputScratch` holds the
    /// flattened input span the resampler walks — flattening it first turns
    /// the ring's wrap-around into two `memcpy`s instead of a branch inside
    /// the per-sample loop. `outputScratch` holds the second resampled block
    /// a jump needs, so the two can be crossfaded.
    ///
    /// Allocated once, because the render thread must never allocate, and
    /// sized to the ring so no block it can be asked for overflows them.
    private let inputScratch: UnsafeMutablePointer<Float>
    private let outputScratch: UnsafeMutablePointer<Float>

    public init(capacityFrames: Int, channelCount: Int) {
        var powerOfTwo = 1
        while powerOfTwo < max(capacityFrames, 1) { powerOfTwo <<= 1 }
        self.capacity = powerOfTwo
        self.mask = powerOfTwo - 1
        self.channelCount = channelCount
        self.storage = (0..<channelCount).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: powerOfTwo)
            pointer.initialize(repeating: 0, count: powerOfTwo)
            return pointer
        }
        inputScratch = UnsafeMutablePointer<Float>.allocate(capacity: powerOfTwo)
        inputScratch.initialize(repeating: 0, count: powerOfTwo)
        outputScratch = UnsafeMutablePointer<Float>.allocate(capacity: powerOfTwo)
        outputScratch.initialize(repeating: 0, count: powerOfTwo)
    }

    deinit {
        for pointer in storage {
            pointer.deallocate()
        }
        inputScratch.deallocate()
        outputScratch.deallocate()
    }

    public var availableFrames: Int {
        max(0, head.load(ordering: .acquiring) - tail.load(ordering: .acquiring))
    }

    /// Empties the buffer. Only call while the consumer is idle (engines
    /// stopped), e.g. during graph rebuilds.
    public func reset() {
        head.store(0, ordering: .releasing)
        tail.store(0, ordering: .releasing)
        primed.store(false, ordering: .releasing)
        producerBlockFrames.store(0, ordering: .releasing)
        // The controller's own state is deliberately *not* cleared here.
        // Everything above is atomic and safe to publish from the control
        // queue; the controller's counters are plain integers owned by the
        // render thread, and writing them from here would be a data race in
        // a way `head` and `tail` are not. Clearing `primed` is enough:
        // nothing reads that state again until the gate reopens, and the
        // prime path starts it from scratch.
    }

    /// The averaged occupancy the rate loop is steering, in frames — the
    /// delay the pipeline is actually carrying. Diagnostics only.
    public var smoothedFill: Int { Int(smoothedOccupancy.rounded()) }

    /// How far the rate loop is currently bending the stream, in parts per
    /// million. This is the number that says whether the two clocks are
    /// close or merely being held together: a steady reading near the
    /// measured hardware drift is the loop working, and a value pinned at
    /// the clamp means something is wrong that a resampler cannot fix.
    public var rateCorrectionPPM: Int { Int(((rateRatio - 1) * 1_000_000).rounded()) }

    // MARK: - Producer (capture path)

    /// Writes a canonical planar buffer. Mono input is duplicated to every
    /// output channel. Overflow drops the oldest frames so the pipeline
    /// always carries the freshest audio.
    public func write(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let sourceChannels = min(channelCount, Int(buffer.format.channelCount))
        guard sourceChannels > 0 else { return }

        // `floatChannelData` hands back non-optional pointers; the raw path
        // takes optionals so an IOProc can pass a partially filled vector.
        let frames = Int(buffer.frameLength)
        withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>?.self, capacity: sourceChannels) { vector in
            for channel in 0..<sourceChannels {
                vector[channel] = channelData[channel]
            }
            write(planar: vector.baseAddress!, sourceChannels: sourceChannels, frames: frames)
        }
    }

    /// Raw-pointer producer path, used by the CoreAudio tap IOProc: one
    /// pointer per source channel, no AVAudioPCMBuffer and no Swift array,
    /// so nothing allocates or takes a lock on the audio thread.
    ///
    /// Fewer source channels than the ring has are duplicated across the
    /// remainder, which is how a mono source fills both sides.
    public func write(planar sources: UnsafePointer<UnsafeMutablePointer<Float>?>, sourceChannels: Int, frames incoming: Int) {
        guard incoming > 0, sourceChannels > 0 else { return }

        // A block bigger than the whole ring can only leave its newest
        // `capacity` frames behind. Without this clamp the wrapped copy
        // below writes `frames - (capacity - index)` floats past the end of
        // the storage — a heap overflow, not just a dropped block.
        let frames = min(incoming, capacity)
        let sourceOffset = incoming - frames

        // Teach the consumer how much slack one late block would cost. The
        // producer is single-threaded, so a plain load/store is enough.
        if frames > producerBlockFrames.load(ordering: .relaxed) {
            producerBlockFrames.store(frames, ordering: .relaxed)
        }

        dropOldest(ifNeededFor: frames)

        let start = head.load(ordering: .relaxed)
        let index = start & mask
        let firstSegment = min(frames, capacity - index)
        let secondSegment = frames - firstSegment

        for channel in 0..<channelCount {
            guard let base = sources[min(channel, sourceChannels - 1)] else { continue }
            let source = base + sourceOffset
            let destination = storage[channel]
            memcpy(destination + index, source, firstSegment * MemoryLayout<Float>.size)
            if secondSegment > 0 {
                memcpy(destination, source + firstSegment, secondSegment * MemoryLayout<Float>.size)
            }
        }

        head.store(start + frames, ordering: .releasing)
    }

    private func dropOldest(ifNeededFor incomingFrames: Int) {
        while true {
            let currentTail = tail.load(ordering: .acquiring)
            let currentHead = head.load(ordering: .relaxed)
            let overflow = (currentHead - currentTail) + incomingFrames - capacity
            if overflow <= 0 { return }
            if tail.compareExchange(expected: currentTail, desired: currentTail + overflow, ordering: .acquiringAndReleasing).exchanged {
                dropCount.add(1, ordering: .relaxed)
                return
            }
        }
    }

    // MARK: - Consumer (render thread)

    /// Planar variant used by channel-strip scratch buffers: one raw
    /// pointer per channel, no AudioBufferList involved.
    @discardableResult
    public func read(frameCount: Int, intoPlanar destinations: inout [UnsafeMutablePointer<Float>?], channelCount: Int) -> Bool {
        let channels = min(channelCount, destinations.count)
        return destinations.withUnsafeMutableBufferPointer { buffer in
            read(frameCount: frameCount, intoPlanar: buffer.baseAddress!, channelCount: channels)
        }
    }

    /// Raw-pointer planar variant. This is the one the render callback
    /// uses: no Swift array, so no exclusivity check or COW machinery runs
    /// on the audio thread.
    @discardableResult
    public func read(frameCount: Int, intoPlanar destinations: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, channelCount: Int) -> Bool {
        let channels = min(channelCount, self.channelCount)
        var start = tail.load(ordering: .relaxed)
        let writePosition = head.load(ordering: .acquiring)
        var available = max(0, writePosition - start)
        let target = targetFrames(consumerFrames: frameCount)

        // The prime gate. While filling, nothing is consumed and nothing is
        // counted — an app that has never played is indistinguishable from
        // one that is between blocks, and neither is a fault.
        guard primed.load(ordering: .relaxed) || available >= target else {
            silence(destinations, frameCount: frameCount, channels: channels, of: channelCount)
            return false
        }
        if !primed.load(ordering: .relaxed) {
            primed.store(true, ordering: .relaxed)
            resetController()
            // Open the gate *on* the target rather than at or above it.
            //
            // The gate waits for `available >= target`, so the occupancy it
            // hands over lands anywhere inside a producer block above the
            // setpoint — and the rate loop would then spend its first
            // seconds bending the stream to remove a surplus that was an
            // accident of timing. Starting at the setpoint costs nothing
            // (the frames skipped have not been played) and leaves the loop
            // with nothing to do but hold.
            let anchored = writePosition - target
            if anchored > start, anchored >= 0 {
                start = anchored
                available = writePosition - start
            }
        }

        // A gross backlog is not something to bend the rate around.
        //
        // The loop corrects at most a fraction of a percent, so a stall that
        // left a tenth of a second in the ring would take half a minute to
        // walk off, all of it audibly late. Anything this far out is a
        // discontinuity in the stream rather than a difference in clocks, so
        // it is jumped in one step and crossfaded — the one place where the
        // splice really is the right tool.
        var crossfadeFrom = -1
        if learnedProducerBlock > 0, available > target + 4 * learnedProducerBlock {
            let anchored = writePosition - target
            if anchored > start,
               anchored >= 0,
               anchored >= writePosition - capacity + learnedProducerBlock {
                crossfadeFrom = start
                start = anchored
                available = writePosition - start
                resyncCount.add(1, ordering: .relaxed)
                readPhase = 0
                rateIntegral = 0
                smoothedOccupancy = setpoint(target: target)
            }
        }

        let ratio = updateRate(occupancy: available, target: target)

        // Input span this block needs. The interpolator reads one sample
        // behind the current position and two ahead, so the window is wider
        // than the frames actually consumed.
        let lastPosition = readPhase + Double(frameCount - 1) * ratio
        let highestIndex = Int(lastPosition.rounded(.down)) + 2
        let inputFrames = highestIndex + 2          // from `start - 1` inclusive

        // Not enough input to satisfy the block. Everything the ring holds
        // is handed over and the rest is silence, which is a hole in a
        // running stream — the audible failure, and the one worth counting.
        guard available > highestIndex, inputFrames + 1 <= capacity else {
            let plain = min(frameCount, available)
            if plain == 0 {
                starvationCount.add(1, ordering: .relaxed)
            } else {
                underrunCount.add(1, ordering: .relaxed)
            }
            primed.store(false, ordering: .relaxed)
            for channel in 0..<channels {
                guard let destination = destinations[channel] else { continue }
                if plain > 0 { copy(channel: channel, from: start, frames: plain, into: destination) }
                vDSP_vclr(destination + plain, 1, vDSP_Length(frameCount - plain))
            }
            if plain > 0 { tail.store(start + plain, ordering: .releasing) }
            clearExtraChannels(destinations, frameCount: frameCount, from: channels, to: channelCount)
            return plain > 0
        }

        for channel in 0..<channels {
            guard let destination = destinations[channel] else { continue }
            copy(channel: channel, from: start - 1, frames: inputFrames, into: inputScratch)
            resample(from: inputScratch, into: destination, frameCount: frameCount, ratio: ratio, phase: readPhase)

            if crossfadeFrom >= 0 {
                copy(channel: channel, from: crossfadeFrom - 1, frames: inputFrames, into: inputScratch)
                resample(from: inputScratch, into: outputScratch, frameCount: frameCount, ratio: ratio, phase: readPhase)
                blend(old: outputScratch, into: destination, frames: frameCount)
            }
        }

        let advanced = readPhase + Double(frameCount) * ratio
        let consumed = Int(advanced.rounded(.down))
        readPhase = advanced - Double(consumed)
        tail.store(start + consumed, ordering: .releasing)

        clearExtraChannels(destinations, frameCount: frameCount, from: channels, to: channelCount)
        return true
    }

    /// Reads `frameCount` output samples from a flat input span, walking it
    /// at `ratio` samples per output sample. `source` is positioned one
    /// sample *before* the read point, which is the interpolator's `x0`.
    @inline(__always)
    private func resample(from source: UnsafePointer<Float>, into destination: UnsafeMutablePointer<Float>,
                          frameCount: Int, ratio: Double, phase: Double) {
        // The common case by a wide margin: the loop has settled and the
        // ratio is within a whisker of unity. Interpolating anyway would put
        // a permanent, if tiny, filter on audio that needs none, so a block
        // that lands exactly on sample boundaries is copied instead.
        if ratio == 1.0 && phase == 0 {
            memcpy(destination, source + 1, frameCount * MemoryLayout<Float>.size)
            return
        }
        for frame in 0..<frameCount {
            let position = phase + Double(frame) * ratio
            let index = Int(position.rounded(.down))
            let fraction = Float(position - Double(index))
            let base = source + index          // `source` is already offset by -1
            destination[frame] = Self.hermite(base[0], base[1], base[2], base[3], fraction)
        }
    }

    @inline(__always)
    private func silence(_ destinations: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                         frameCount: Int, channels: Int, of totalChannels: Int) {
        for channel in 0..<channels {
            guard let destination = destinations[channel] else { continue }
            vDSP_vclr(destination, 1, vDSP_Length(frameCount))
        }
        clearExtraChannels(destinations, frameCount: frameCount, from: channels, to: totalChannels)
    }

    @inline(__always)
    private func clearExtraChannels(_ destinations: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                                    frameCount: Int, from: Int, to: Int) {
        for channel in from..<to {
            guard let destination = destinations[channel] else { continue }
            vDSP_vclr(destination, 1, vDSP_Length(frameCount))
        }
    }

    /// Copies `frames` from an absolute stream position, in at most two
    /// contiguous segments.
    @inline(__always)
    private func copy(channel: Int, from position: Int, frames: Int, into destination: UnsafeMutablePointer<Float>) {
        let index = position & mask
        let firstSegment = min(frames, capacity - index)
        let source = storage[channel]
        memcpy(destination, source + index, firstSegment * MemoryLayout<Float>.size)
        if frames > firstSegment {
            memcpy(destination + firstSegment, source, (frames - firstSegment) * MemoryLayout<Float>.size)
        }
    }

    /// Ramps `destination` (the new read position) up while `old` ramps
    /// down, in place, across the whole block.
    ///
    /// A linear crossfade rather than an equal-power one. The two sides are
    /// the same programme material a tenth of a second apart, so they are
    /// effectively uncorrelated and a linear fade dips about 3 dB at the
    /// midpoint — but the midpoint lasts under three milliseconds and this
    /// happens on the order of once an hour, whereas the alternative it
    /// replaces was a hard splice every few seconds. `vDSP_vrampmul`
    /// advances its start value in place, so each side needs its own copy.
    @inline(__always)
    private func blend(old: UnsafeMutablePointer<Float>, into destination: UnsafeMutablePointer<Float>, frames: Int) {
        let length = vDSP_Length(frames)
        var step = 1.0 / Float(frames)
        var rise: Float = 0
        vDSP_vrampmul(destination, 1, &rise, &step, destination, 1, length)
        var fall: Float = 1
        var negativeStep = -step
        vDSP_vrampmul(old, 1, &fall, &negativeStep, old, 1, length)
        vDSP_vadd(destination, 1, old, 1, destination, 1, length)
    }
}

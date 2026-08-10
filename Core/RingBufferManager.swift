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
    /// A completely empty read is not counted. An app that is not playing
    /// has an empty ring by definition and reading silence from it is the
    /// correct outcome, not a fault; counting those buries the real signal
    /// under one hit per render callback per idle app.
    ///
    /// A drop is a write that overwrote frames the consumer never read.
    private let underrunCount = Atomic<Int>(0)
    private let dropCount = Atomic<Int>(0)

    public var underruns: Int { underrunCount.load(ordering: .relaxed) }
    public var drops: Int { dropCount.load(ordering: .relaxed) }

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
    }

    deinit {
        for pointer in storage {
            pointer.deallocate()
        }
    }

    public var availableFrames: Int {
        max(0, head.load(ordering: .acquiring) - tail.load(ordering: .acquiring))
    }

    /// Empties the buffer. Only call while the consumer is idle (engines
    /// stopped), e.g. during graph rebuilds.
    public func reset() {
        head.store(0, ordering: .releasing)
        tail.store(0, ordering: .releasing)
    }

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
        let start = tail.load(ordering: .relaxed)
        let available = max(0, head.load(ordering: .acquiring) - start)
        let toRead = min(frameCount, available)

        if toRead > 0 && toRead < frameCount {
            underrunCount.add(1, ordering: .relaxed)
        }

        if toRead > 0 {
            let index = start & mask
            let firstSegment = min(toRead, capacity - index)
            let secondSegment = toRead - firstSegment

            for channel in 0..<channels {
                guard let destination = destinations[channel] else { continue }
                let source = storage[channel]
                memcpy(destination, source + index, firstSegment * MemoryLayout<Float>.size)
                if secondSegment > 0 {
                    memcpy(destination + firstSegment, source, secondSegment * MemoryLayout<Float>.size)
                }
                if toRead < frameCount {
                    vDSP_vclr(destination + toRead, 1, vDSP_Length(frameCount - toRead))
                }
            }
            tail.store(start + toRead, ordering: .releasing)
        } else {
            for channel in 0..<channels {
                guard let destination = destinations[channel] else { continue }
                vDSP_vclr(destination, 1, vDSP_Length(frameCount))
            }
        }

        // Zero any channels beyond the ring's own channel count.
        for channel in channels..<channelCount {
            guard let destination = destinations[channel] else { continue }
            vDSP_vclr(destination, 1, vDSP_Length(frameCount))
        }

        return toRead > 0
    }
}

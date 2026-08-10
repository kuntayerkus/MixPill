import Foundation
import Darwin
import Synchronization

/// Real-time thread hygiene for the audio render path.
enum RealtimeThread {
    /// Elevates the calling thread with the Mach time-constraint policy so
    /// the kernel schedules it with hard real-time priority.
    ///
    /// Each output engine calls this **once**, from its own render thread,
    /// and owns the "already attempted" flag itself. A single process-wide
    /// flag would be wrong twice over: only the first engine's thread would
    /// ever be elevated, and a failure would be re-logged on every single
    /// render callback.
    ///
    /// - period: the time between render callbacks (buffer / sampleRate).
    /// - computation: budget we claim to need (half the period — the mix
    ///   is pure vDSP and finishes orders of magnitude sooner).
    /// - constraint: the deadline we must meet (90% of the period, leaving
    ///   headroom without surrendering priority).
    static func applyTimeConstraintPolicy(bufferFrames: UInt32, sampleRate: Double) {
        guard bufferFrames > 0, sampleRate > 0 else { return }

        var timebase = mach_timebase_info()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS,
              timebase.numer > 0, timebase.denom > 0 else { return }

        // The policy is expressed in mach absolute-time ticks, and
        // `mach_absolute_time` converts to nanoseconds as
        // `ns = ticks * numer / denom`. So one second is
        // `1e9 * denom / numer` ticks — the 1e9 matters: without it the
        // ratio alone (3/125 on Apple Silicon) made every field truncate
        // to 0 and `thread_policy_set` rejected the call with
        // KERN_INVALID_ARGUMENT, so no render thread was ever elevated.
        let ticksPerSecond = 1_000_000_000.0 * Double(timebase.denom) / Double(timebase.numer)
        let periodTicks = (Double(bufferFrames) / sampleRate) * ticksPerSecond
        guard periodTicks >= 1 else { return }

        var policy = thread_time_constraint_policy(
            period: UInt32(periodTicks),
            computation: UInt32(periodTicks * 0.5),
            constraint: UInt32(periodTicks * 0.9),
            preemptible: 0
        )

        let count = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size
        )
        let thread = mach_thread_self()
        let result = withUnsafeMutablePointer(to: &policy) { policyPointer in
            policyPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                thread_policy_set(thread, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), raw, count)
            }
        }
        mach_port_deallocate(mach_task_self_, thread)

        if result == KERN_SUCCESS {
            MixPillCoreLog.log("RealtimeThread: time-constraint policy applied (\(bufferFrames) frames @ \(Int(sampleRate)) Hz)")
        } else {
            MixPillCoreLog.log("RealtimeThread: could not apply time-constraint policy (kr \(result))")
        }
    }
}

/// Lock-free transport for small parameter blocks between the control
/// queue (writer, serialized) and the real-time render thread (reader).
///
/// Implementation: an atomic pointer to an immutable boxed value. The
/// writer boxes the new value, atomically swaps the pointer in, and parks
/// the retired box in a FIFO it only drains after several more writes.
/// The render thread only ever performs an atomic pointer load and an
/// unretained dereference — no retain/release, no lock, no allocation.
///
/// Safety invariant: a retired box stays alive for at least
/// `retiredKeepCount` subsequent writes. Control writes arrive at UI
/// cadence (worst case a slider drag, ~60 Hz); render callbacks run every
/// few milliseconds, so any pointer a render pass can observe is
/// guaranteed to outlive that pass by a wide margin.
final class RTParameterStore<Value>: @unchecked Sendable {
    private final class Box {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private let retiredKeepCount = 8

    private let current = Atomic<UnsafeMutableRawPointer?>(nil)
    private let retireLock = NSLock()
    private var retired: [Box] = []

    init(initial: Value) {
        let box = Box(initial)
        current.store(Unmanaged.passRetained(box).toOpaque(), ordering: .releasing)
    }

    /// Render thread: observe the current parameter block.
    func load() -> Value {
        guard let pointer = current.load(ordering: .acquiring) else {
            fatalError("RTParameterStore used before initialization")
        }
        return Unmanaged<Box>.fromOpaque(pointer).takeUnretainedValue().value
    }

    /// Control queue only (writers must be serialized by the caller).
    func store(_ value: Value) {
        let box = Box(value)
        let previous = current.exchange(Unmanaged.passRetained(box).toOpaque(), ordering: .acquiringAndReleasing)

        retireLock.lock()
        if let previous {
            retired.append(Unmanaged<Box>.fromOpaque(previous).takeRetainedValue())
        }
        if retired.count > retiredKeepCount {
            retired.removeFirst(retired.count - retiredKeepCount)
        }
        retireLock.unlock()
    }
}

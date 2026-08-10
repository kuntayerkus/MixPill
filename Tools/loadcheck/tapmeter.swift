import Foundation
import CoreAudio
import AudioToolbox
import Accelerate

// Measures what one process actually puts out, by tapping it.
//
//   tapmeter <bundle-id> <seconds> [label]
//
// Reports RMS/peak (calibrated back through the stereo mixdown's
// attenuation), silence gaps, waveform discontinuities, late capture
// blocks and CoreAudio overloads. The tap is deliberately *unmuted*: this
// observes, it must not change what the speakers do.

// MARK: - HAL helpers

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func stringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr,
          let string = value?.takeRetainedValue() else { return nil }
    return string as String
}

func boolProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var value: UInt32 = 0
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else { return false }
    return value != 0
}

func processObjectIDs() -> [AudioObjectID] {
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
          size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func defaultOutputChannelCount() -> Int {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return 2 }

    var streamAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: kAudioDevicePropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
    var listSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &streamAddr, 0, nil, &listSize) == noErr, listSize > 0 else { return 2 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(listSize), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &streamAddr, 0, nil, &listSize, raw) == noErr else { return 2 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

// MARK: - Accumulator (IO thread only)

final class Meter {
    var sampleRate: Double = 48000
    var compensation: Float = 1

    var frames: Int = 0
    var sumSquares: Double = 0
    var peak: Float = 0

    /// Gap detection only arms once real signal has been seen, so the
    /// silence before playback starts is not counted as a dropout.
    var armed = false
    var silentRun = 0
    var gapCount = 0
    var gapFrames = 0
    var longestGap = 0

    /// A step in the waveform between two samples that are both signal.
    var clicks = 0
    var previousSample: Float = 0
    var previousWasSignal = false

    /// Frames ignored at the start of the run.
    ///
    /// Creating this tap's own aggregate device is itself a HAL topology
    /// change, and the thing being measured reacts to those. Counting from
    /// the first block would put the instrument's own footprint inside the
    /// measurement window.
    var warmupFrames = 0
    var seenFrames = 0

    var blocks = 0
    var lateBlocks = 0
    var lastHostTime: UInt64 = 0
    var expectedInterval: UInt64 = 0
    var overloads = 0

    /// −70 dBFS: below any programme material, above the noise floor of a
    /// digital silence that is not quite zero.
    var silenceThreshold: Float = 0.000316
    /// A 1 kHz sine at −20 dBFS steps by at most 0.0131 per sample; 0.05 is
    /// clear of that and clear of the mixdown's own rounding.
    var clickThreshold: Float = 0.05
    /// Silence shorter than this is a zero crossing, not a dropout.
    var minGapFrames: Int = 48   // 1 ms at 48 kHz
}

let meter = Meter()

// MARK: - Arguments

let args = CommandLine.arguments
guard args.count >= 3, let seconds = Double(args[2]) else {
    FileHandle.standardError.write("usage: tapmeter <bundle-id> <seconds> [label] [warmup-seconds]\n".data(using: .utf8)!)
    exit(2)
}
let targetBundleID = args[1]
let label = args.count > 3 ? args[3] : targetBundleID
let warmup = args.count > 4 ? (Double(args[4]) ?? 0) : 3.0

// MARK: - Find the target's audio process objects

var targets: [AudioObjectID] = []
for objectID in processObjectIDs() {
    guard let bundleID = stringProperty(objectID, kAudioProcessPropertyBundleID) else { continue }
    if bundleID == targetBundleID { targets.append(objectID) }
}

guard !targets.isEmpty else {
    print("{\"label\":\"\(label)\",\"error\":\"no audio process object for \(targetBundleID)\"}")
    exit(3)
}

let playing = targets.contains { boolProperty($0, kAudioProcessPropertyIsRunningOutput) }

// MARK: - Tap

let description = CATapDescription(stereoMixdownOfProcesses: targets)
description.name = "tapmeter — \(label)"
description.uuid = UUID()
description.isPrivate = true
// Observing, not intercepting: the app keeps playing to the speakers.
description.muteBehavior = .unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
    print("{\"label\":\"\(label)\",\"error\":\"tap failed (\(tapStatus))\"}")
    exit(4)
}

var format = AudioStreamBasicDescription()
var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var formatAddr = address(kAudioTapPropertyFormat)
guard AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &formatSize, &format) == noErr else {
    AudioHardwareDestroyProcessTap(tapID)
    print("{\"label\":\"\(label)\",\"error\":\"no tap format\"}")
    exit(5)
}
meter.sampleRate = format.mSampleRate
meter.minGapFrames = max(1, Int(format.mSampleRate / 1000))
meter.warmupFrames = Int(warmup * format.mSampleRate)

let deviceChannels = defaultOutputChannelCount()
meter.compensation = Float(max(1, deviceChannels / 2))

let aggregateUID = "com.mixpill.tapmeter.\(description.uuid.uuidString)"
let aggregate: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "tapmeter",
    kAudioAggregateDeviceUIDKey as String: aggregateUID,
    kAudioAggregateDeviceIsPrivateKey as String: true,
    kAudioAggregateDeviceIsStackedKey as String: false,
    kAudioAggregateDeviceTapAutoStartKey as String: true,
    kAudioAggregateDeviceSubDeviceListKey as String: [],
    kAudioAggregateDeviceTapListKey as String: [[
        kAudioSubTapUIDKey as String: description.uuid.uuidString,
        kAudioSubTapDriftCompensationKey as String: true,
    ]],
]

var aggregateID = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr,
      aggregateID != kAudioObjectUnknown else {
    AudioHardwareDestroyProcessTap(tapID)
    print("{\"label\":\"\(label)\",\"error\":\"aggregate failed\"}")
    exit(6)
}

var captureFrames: UInt32 = 1024
var frameAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
AudioObjectSetPropertyData(aggregateID, &frameAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &captureFrames)
var actualFrames: UInt32 = 0
var actualSize = UInt32(MemoryLayout<UInt32>.size)
AudioObjectGetPropertyData(aggregateID, &frameAddr, 0, nil, &actualSize, &actualFrames)
if actualFrames > 0 {
    var timebase = mach_timebase_info()
    if mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0 {
        let ticks = Double(actualFrames) / meter.sampleRate * 1_000_000_000.0 * Double(timebase.denom) / Double(timebase.numer)
        meter.expectedInterval = UInt64(ticks)
    }
}

var overloadAddr = address(kAudioDeviceProcessorOverload)
let overloadQueue = DispatchQueue(label: "tapmeter.overload")
let overloadBlock: AudioObjectPropertyListenerBlock = { _, _ in
    meter.overloads += 1
}
AudioObjectAddPropertyListenerBlock(aggregateID, &overloadAddr, overloadQueue, overloadBlock)

var ioProcID: AudioDeviceIOProcID?
let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, _, _ in
    let now = mach_absolute_time()
    if meter.lastHostTime != 0, meter.expectedInterval != 0 {
        if (now &- meter.lastHostTime) > meter.expectedInterval * 18 / 10 { meter.lateBlocks += 1 }
    }
    meter.lastHostTime = now
    meter.blocks += 1

    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard buffers.count > 0, let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
    let channels = max(1, Int(buffers[0].mNumberChannels))
    let totalFloats = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
    let frameCount = buffers.count > 1 ? totalFloats : totalFloats / channels
    guard frameCount > 0 else { return }

    let gain = meter.compensation
    for frame in 0..<frameCount {
        // Mono-sum the pair; a dropout takes both sides with it.
        let left = data[buffers.count > 1 ? frame : frame * channels] * gain
        let sample = left

        let isSignalNow = abs(sample) >= meter.silenceThreshold
        if meter.seenFrames < meter.warmupFrames {
            meter.seenFrames += 1
            meter.previousSample = sample
            meter.previousWasSignal = isSignalNow
            continue
        }

        meter.frames += 1
        meter.sumSquares += Double(sample) * Double(sample)
        meter.peak = max(meter.peak, abs(sample))

        let isSignal = abs(sample) >= meter.silenceThreshold
        if isSignal { meter.armed = true }

        if meter.armed {
            if isSignal {
                if meter.silentRun >= meter.minGapFrames {
                    meter.gapCount += 1
                    meter.gapFrames += meter.silentRun
                    meter.longestGap = max(meter.longestGap, meter.silentRun)
                }
                meter.silentRun = 0
                if meter.previousWasSignal, abs(sample - meter.previousSample) > meter.clickThreshold {
                    meter.clicks += 1
                }
            } else {
                meter.silentRun += 1
            }
        }
        meter.previousSample = sample
        meter.previousWasSignal = isSignal
    }
}

guard ioStatus == noErr, let ioProcID else {
    AudioHardwareDestroyAggregateDevice(aggregateID)
    AudioHardwareDestroyProcessTap(tapID)
    print("{\"label\":\"\(label)\",\"error\":\"ioproc failed (\(ioStatus))\"}")
    exit(7)
}

AudioDeviceStart(aggregateID, ioProcID)
Thread.sleep(forTimeInterval: seconds + warmup)
AudioDeviceStop(aggregateID, ioProcID)

// A run that never saw signal is still trailing silence.
if meter.armed, meter.silentRun >= meter.minGapFrames {
    meter.gapCount += 1
    meter.gapFrames += meter.silentRun
    meter.longestGap = max(meter.longestGap, meter.silentRun)
}

AudioObjectRemovePropertyListenerBlock(aggregateID, &overloadAddr, overloadQueue, overloadBlock)
AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
AudioHardwareDestroyAggregateDevice(aggregateID)
AudioHardwareDestroyProcessTap(tapID)

// MARK: - Report

func decibels(_ amplitude: Double) -> Double {
    20 * log10(max(amplitude, 1e-9))
}

let rms = meter.frames > 0 ? (meter.sumSquares / Double(meter.frames)).squareRoot() : 0
let captured = Double(meter.frames) / meter.sampleRate

var report: [String: Any] = [
    "label": label,
    "bundleID": targetBundleID,
    "processObjects": targets.count,
    "wasPlayingAtStart": playing,
    "sampleRate": meter.sampleRate,
    "mixdownCompensation": meter.compensation,
    "capturedSeconds": (captured * 100).rounded() / 100,
    "blocks": meter.blocks,
    "rmsDBFS": (decibels(rms) * 100).rounded() / 100,
    "peakDBFS": (decibels(Double(meter.peak)) * 100).rounded() / 100,
    "gaps": meter.gapCount,
    "gapMilliseconds": ((Double(meter.gapFrames) / meter.sampleRate * 1000) * 10).rounded() / 10,
    "longestGapMilliseconds": ((Double(meter.longestGap) / meter.sampleRate * 1000) * 10).rounded() / 10,
    "clicks": meter.clicks,
    "lateBlocks": meter.lateBlocks,
    "overloads": meter.overloads,
]
if !meter.armed { report["note"] = "no signal seen" }

let json = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))

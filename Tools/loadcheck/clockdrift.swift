import Foundation
import CoreAudio
import AudioToolbox
import Accelerate

// Measures the two clocks MixPill's pipeline actually straddles:
//
//   producer — a process tap's aggregate device (what ProcessTapCapture uses)
//   consumer — an AUHAL output unit on the default output device
//
// Both are run for N seconds and their delivered/consumed frame counts are
// divided by the same wall clock. If those two rates differ, the ring
// between them must either grow or shrink without bound, and no buffer
// size can fix that — only rate matching can.
//
//   clockdrift <bundle-id> <seconds>

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
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

let args = CommandLine.arguments
guard args.count >= 3, let seconds = Double(args[2]) else {
    print("usage: clockdrift <bundle-id> <seconds>"); exit(2)
}
let wantedBundle = args[1]

// MARK: - default output device

var defaultAddr = address(kAudioHardwarePropertyDefaultOutputDevice)
var outputDevice = AudioDeviceID(0)
var devSize = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &devSize, &outputDevice)
let outputUID = stringProperty(outputDevice, kAudioDevicePropertyDeviceUID) ?? "?"
let outputName = stringProperty(outputDevice, kAudioObjectPropertyName) ?? "?"

var rateAddr = address(kAudioDevicePropertyNominalSampleRate)
var nominalRate: Double = 0
var rateSize = UInt32(MemoryLayout<Double>.size)
AudioObjectGetPropertyData(outputDevice, &rateAddr, 0, nil, &rateSize, &nominalRate)

var actualAddr = address(kAudioDevicePropertyActualSampleRate)
var actualRate: Double = 0
var actualSize = UInt32(MemoryLayout<Double>.size)
let haveActual = AudioObjectGetPropertyData(outputDevice, &actualAddr, 0, nil, &actualSize, &actualRate) == noErr

// MARK: - find the target process objects

var listAddr = address(kAudioHardwarePropertyProcessObjectList)
var listSize: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &listSize)
var processIDs = [AudioObjectID](repeating: 0, count: Int(listSize) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &listSize, &processIDs)

let targets = processIDs.filter { id in
    guard let bundle = stringProperty(id, kAudioProcessPropertyBundleID) else { return false }
    return bundle == wantedBundle || bundle.hasPrefix(wantedBundle)
}
guard !targets.isEmpty else {
    print("{\"error\":\"no audio process object for \(wantedBundle)\"}"); exit(1)
}

// MARK: - producer: a tap aggregate exactly like ProcessTapCapture builds

let description = CATapDescription(stereoMixdownOfProcesses: targets)
description.name = "clockdrift probe"
description.uuid = UUID()
description.isPrivate = true
description.muteBehavior = .unmuted          // observe, never change what plays

var tapID = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != kAudioObjectUnknown else {
    print("{\"error\":\"tap creation failed\"}"); exit(1)
}

var tapFormatAddr = address(kAudioTapPropertyFormat)
var tapFormat = AudioStreamBasicDescription()
var tapFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioObjectGetPropertyData(tapID, &tapFormatAddr, 0, nil, &tapFormatSize, &tapFormat)

let aggregateUID = "com.mixpill.clockdrift.\(description.uuid.uuidString)"
let aggregateSpec: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "clockdrift probe",
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
guard AudioHardwareCreateAggregateDevice(aggregateSpec as CFDictionary, &aggregateID) == noErr else {
    print("{\"error\":\"aggregate failed\"}"); AudioHardwareDestroyProcessTap(tapID); exit(1)
}

var captureFrames: UInt32 = 1024
var frameAddr = address(kAudioDevicePropertyBufferFrameSize)
AudioObjectSetPropertyData(aggregateID, &frameAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &captureFrames)

final class Counter {
    var frames = 0
    var blocks = 0
    var firstHost: UInt64 = 0
    var lastHost: UInt64 = 0
    // Frames delivered before the measurement window opens.
    var warmupUntil: UInt64 = 0
    var started = false
}
let producer = Counter()
let consumer = Counter()

var timebase = mach_timebase_info()
mach_timebase_info(&timebase)
func nanos(_ ticks: UInt64) -> Double { Double(ticks) * Double(timebase.numer) / Double(timebase.denom) }

var ioProcID: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, _, _ in
    let now = mach_absolute_time()
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard buffers.count > 0 else { return }
    let channels = max(1, Int(buffers[0].mNumberChannels))
    let frames = buffers.count > 1
        ? Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        : Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size / channels
    guard frames > 0 else { return }
    if now < producer.warmupUntil { return }
    if !producer.started { producer.started = true; producer.firstHost = now; return }
    producer.frames += frames
    producer.blocks += 1
    producer.lastHost = now
}

// MARK: - consumer: an AUHAL output unit on the same device, rendering silence

var componentDescription = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0)
let component = AudioComponentFindNext(nil, &componentDescription)!
var unit: AudioUnit?
AudioComponentInstanceNew(component, &unit)
let outputUnit = unit!

var target = outputDevice
AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice,
                     kAudioUnitScope_Global, 0, &target, UInt32(MemoryLayout<AudioDeviceID>.size))

// Exactly the client format LowLatencyMixerEngine asks for.
var clientFormat = AudioStreamBasicDescription(
    mSampleRate: nominalRate,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: UInt32(kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved),
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
    mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                     &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

var renderCallback = AURenderCallbackStruct(
    inputProc: { refCon, _, _, _, inNumberFrames, ioData in
        let now = mach_absolute_time()
        let counter = Unmanaged<Counter>.fromOpaque(refCon).takeUnretainedValue()
        if let ioData {
            let abl = UnsafeMutableAudioBufferListPointer(ioData)
            for i in 0..<abl.count {
                if let data = abl[i].mData {
                    vDSP_vclr(data.assumingMemoryBound(to: Float.self), 1, vDSP_Length(inNumberFrames))
                }
            }
        }
        if now < counter.warmupUntil { return noErr }
        if !counter.started { counter.started = true; counter.firstHost = now; return noErr }
        counter.frames += Int(inNumberFrames)
        counter.blocks += 1
        counter.lastHost = now
        return noErr
    },
    inputProcRefCon: Unmanaged.passUnretained(consumer).toOpaque())
AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                     &renderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

// Report the block size the device actually gives the output unit.
var playbackFrames: UInt32 = 256
AudioUnitSetProperty(outputUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                     &playbackFrames, UInt32(MemoryLayout<UInt32>.size))
var actualPlaybackFrames: UInt32 = 0
var actualPlaybackSize = UInt32(MemoryLayout<UInt32>.size)
AudioUnitGetProperty(outputUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                     &actualPlaybackFrames, &actualPlaybackSize)

// 3-second warmup on both sides: creating the aggregate is itself a HAL
// topology change and the device resettles after it.
let warmupTicks = UInt64(3.0 * 1_000_000_000.0 * Double(timebase.denom) / Double(timebase.numer))
let startTick = mach_absolute_time()
producer.warmupUntil = startTick + warmupTicks
consumer.warmupUntil = startTick + warmupTicks

AudioUnitInitialize(outputUnit)
AudioOutputUnitStart(outputUnit)
AudioDeviceStart(aggregateID, ioProcID!)

Thread.sleep(forTimeInterval: seconds + 3.0)

AudioDeviceStop(aggregateID, ioProcID!)
AudioOutputUnitStop(outputUnit)
AudioUnitUninitialize(outputUnit)
AudioComponentInstanceDispose(outputUnit)
AudioDeviceDestroyIOProcID(aggregateID, ioProcID!)
AudioHardwareDestroyAggregateDevice(aggregateID)
AudioHardwareDestroyProcessTap(tapID)

func rate(_ counter: Counter) -> Double {
    let span = nanos(counter.lastHost &- counter.firstHost) / 1_000_000_000.0
    guard span > 0 else { return 0 }
    // lastHost is the *start* of the final block, so its frames are already
    // counted but its time is not; that is the same convention on both
    // sides, and over a minute the bias is far below the effect measured.
    return Double(counter.frames) / span
}

let producerRate = rate(producer)
let consumerRate = rate(consumer)
let ppm = consumerRate > 0 ? (producerRate - consumerRate) / consumerRate * 1_000_000 : 0
let framesPerHour = (producerRate - consumerRate) * 3600

let report: [String: Any] = [
    "outputDevice": outputName,
    "outputUID": outputUID,
    "nominalSampleRate": nominalRate,
    "actualSampleRate": haveActual ? actualRate : 0,
    "tapFormatSampleRate": tapFormat.mSampleRate,
    "tapChannels": Int(tapFormat.mChannelsPerFrame),
    "playbackBlockFrames": Int(actualPlaybackFrames),
    "captureBlockFrames": Int(captureFrames),
    "producerBlocks": producer.blocks,
    "producerFrames": producer.frames,
    "producerRateHz": producerRate,
    "consumerBlocks": consumer.blocks,
    "consumerFrames": consumer.frames,
    "consumerRateHz": consumerRate,
    "driftPPM": ppm,
    "ringDriftFramesPerHour": framesPerHour,
]
let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)

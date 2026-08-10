import Foundation
import CoreAudio

/// CoreAudio HAL device registry for the core service: enumerates output
/// devices, tracks the system default, can move the system default, and
/// watches topology changes.
///
/// Device IDs are ephemeral across `coreaudiod` restarts, so everything
/// persisted or exposed is keyed by device **UID**; IDs are resolved on
/// demand through this registry.
final class DeviceRegistry: @unchecked Sendable {
    struct Device: Hashable, Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let channelCount: Int
    }

    private let lock = UnfairLock()
    private var devices: [Device] = []
    private var defaultDeviceUID: String?

    /// Invoked on the registered dispatch queue whenever the device list
    /// or the default output changes. Multiple subsystems observe.
    private let observerLock = UnfairLock()
    private var observers: [() -> Void] = []
    var changeQueue: DispatchQueue?

    func addObserver(_ observer: @escaping () -> Void) {
        observerLock.withLockVoid { observers.append(observer) }
    }

    private func notifyObservers() {
        let current = observerLock.withLock { observers }
        for observer in current {
            observer()
        }
    }

    private var listenersRegistered = false

    // MARK: - Snapshot access

    func snapshot() -> (devices: [Device], defaultDeviceUID: String?) {
        lock.withLock { (devices, defaultDeviceUID) }
    }

    func outputDevices() -> [Device] {
        lock.withLock { devices }
    }

    func defaultOutputDeviceUID() -> String? {
        lock.withLock { defaultDeviceUID }
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        lock.withLock { devices.first(where: { $0.uid == uid })?.id }
    }

    func channelCount(forUID uid: String) -> Int {
        lock.withLock { devices.first(where: { $0.uid == uid })?.channelCount ?? 2 }
    }

    /// The pair of output channels macOS treats as this device's stereo
    /// front left/right, as zero-based indices.
    ///
    /// This matters on wide interfaces. A 64-channel desk carries an app's
    /// stereo output in exactly two of its channels, and this says which —
    /// so a capture in the device's native format can pull the right pair
    /// out instead of averaging all 64 into silence-diluted mush.
    func preferredStereoChannels(forUID uid: String) -> (left: Int, right: Int) {
        guard let deviceID = deviceID(forUID: uid) else { return (0, 1) }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var channels: (UInt32, UInt32) = (1, 2)
        var dataSize = UInt32(MemoryLayout<UInt32>.size * 2)
        let status = withUnsafeMutablePointer(to: &channels) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, channels.0 > 0, channels.1 > 0 else { return (0, 1) }

        // The HAL reports channel *numbers*, which are 1-based.
        return (Int(channels.0) - 1, Int(channels.1) - 1)
    }


    /// Nominal sample rate of the current default output device. Doubles
    /// as a `coreaudiod` liveness probe: it fails while the daemon is down.
    func defaultDeviceNominalSampleRate() -> Double? {
        let deviceID = fetchDefaultOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate) == noErr else {
            return nil
        }
        return sampleRate
    }

    // MARK: - Default output control

    /// Moves the macOS system default output onto the device with this
    /// UID, so MixPill can offer "make this the system output" next to the
    /// per-app routing rather than sending people to Sound settings.
    @discardableResult
    func setDefaultOutputDevice(uid: String) -> Bool {
        guard let deviceID = deviceID(forUID: uid) else {
            MixPillCoreLog.log("DeviceRegistry: no device with UID \(uid)")
            return false
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var target = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &target
        )
        if status != noErr {
            MixPillCoreLog.log("DeviceRegistry: could not set default output device (status \(status))")
        }
        return status == noErr
    }

    // MARK: - Enumeration

    /// Re-enumerates devices and the default output. Returns true when the
    /// topology or the default actually changed.
    @discardableResult
    func refresh() -> Bool {
        let newDevices = enumerateOutputDevices()
        let newDefaultUID = uid(ofDeviceID: fetchDefaultOutputDeviceID())

        return lock.withLock {
            let changed = newDevices != devices || newDefaultUID != defaultDeviceUID
            devices = newDevices
            defaultDeviceUID = newDefaultUID
            return changed
        }
    }

    private func enumerateOutputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            let channelCount = outputChannelCount(deviceID)
            guard channelCount > 0 else { return nil }
            guard let name = deviceName(deviceID), let uid = deviceUID(deviceID) else { return nil }
            return Device(id: deviceID, uid: uid, name: name, channelCount: channelCount)
        }
    }

    private func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }

        let listMemory = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listMemory.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, listMemory) == noErr else {
            return 0
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(listMemory.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        // Read into an Unmanaged slot rather than a `var CFString`.
        // Pointing CoreAudio at a Swift variable holding an object
        // reference lets it overwrite a managed pointer behind ARC's back.
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &uid) == noErr,
              let value = uid?.takeRetainedValue() else { return nil }
        return value as String
    }

    private func fetchDefaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID) == noErr else {
            return kAudioObjectUnknown
        }
        return deviceID
    }

    private func uid(ofDeviceID deviceID: AudioDeviceID) -> String? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        return deviceUID(deviceID)
    }

    // MARK: - Change listeners

    func startListening() {
        let alreadyRegistered = lock.withLock {
            let alreadyRegistered = listenersRegistered
            listenersRegistered = true
            return alreadyRegistered
        }
        guard !alreadyRegistered else { return }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, changeQueue ?? .global()) { [weak self] _, _ in
            guard let self else { return }
            if self.refresh() {
                self.notifyObservers()
            }
        }

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, changeQueue ?? .global()) { [weak self] _, _ in
            guard let self else { return }
            if self.refresh() {
                self.notifyObservers()
            }
        }
    }
}

import Foundation
import CoreAudio
import AppKit
import Darwin

/// Discovery of audio-producing applications, straight from the CoreAudio
/// HAL.
///
/// This replaces the old ScreenCaptureKit enumeration, and it is a better
/// fit in every direction. `SCShareableContent` answered "which
/// applications own a window", which is not the question — it listed
/// Finder and Notes alongside Spotify, needed the Screen & System Audio
/// Recording grant just to be asked, and had to be polled on a timer.
/// The HAL's process object list answers the actual question — which
/// processes are wired into the audio system, and which are producing
/// output right now — needs no TCC grant to enumerate, and posts change
/// notifications instead of being polled.
final class AudioProcessRegistry: @unchecked Sendable {
    /// One user-facing application, together with every audio process
    /// object that belongs to it.
    ///
    /// The grouping matters: a browser plays through a helper process, not
    /// through the process the user thinks of as "Chrome". Listing those
    /// helpers separately would put `com.google.Chrome.helper` in the
    /// mixer next to `cloudpaird`, which is not a product. One tap covers
    /// all of an app's process objects, so the user gets one strip called
    /// "Google Chrome" that actually controls its sound.
    struct AudioProcess: Equatable {
        let objectIDs: [AudioObjectID]
        let bundleID: String
        let name: String
        /// Currently sending audio to an output device.
        let isPlaying: Bool
        /// Currently holding an input stream — i.e. the microphone is open.
        /// This is what identifies a call, without guessing from bundle ids.
        let isCapturingInput: Bool
    }

    private let queue = DispatchQueue(label: "com.mixpill.core.processes", qos: .utility)
    private var processes: [AudioProcess] = []
    private var running = false

    /// Listener blocks per audio process object, keyed by selector.
    ///
    /// Kept rather than a bare id set because
    /// `AudioObjectRemovePropertyListenerBlock` matches on the block
    /// itself. Without them the listeners installed on every process object
    /// were never taken off: a long-lived core service that has seen a few
    /// hundred app launches accumulated a few hundred retained closures
    /// bound to objects that no longer exist.
    private var observedObjects: [AudioObjectID: [AudioObjectPropertyListenerBlock]] = [:]

    /// The two properties that say whether a process is playing or
    /// listening; a change in either is what makes the list refresh.
    private static let observedSelectors: [AudioObjectPropertySelector] = [
        kAudioProcessPropertyIsRunningOutput,
        kAudioProcessPropertyIsRunningInput
    ]

    /// Bundle identifiers never captured (MixPill's own processes).
    private let excludedBundleIDs: Set<String>

    /// Fires whenever the reported set of applications changes.
    var onProcessesChanged: ((_ processes: [AudioProcess]) -> Void)?

    init(excludedBundleIDs: Set<String>) {
        self.excludedBundleIDs = excludedBundleIDs
    }

    var currentProcesses: [AudioProcess] {
        queue.sync { processes }
    }

    // MARK: - Lifecycle

    func start() {
        queue.sync {
            guard !running else { return }
            running = true
        }

        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
            self?.refreshLocked()
        }

        queue.async { self.refreshLocked() }
    }

    func stop() {
        queue.sync {
            running = false
            processes = []
            for objectID in observedObjects.keys {
                unobserve(objectID)
            }
        }
    }

    // MARK: - Enumeration

    /// Rebuilds the process list. Runs on `queue`, which is also the queue
    /// every HAL listener block is delivered on, so the state below needs
    /// no additional locking.
    private func refreshLocked() {
        guard running else { return }

        // Accumulate every audio process object under the application that
        // owns it, dropping anything that is not a user-facing app.
        var grouped: [String: (name: String, objectIDs: [AudioObjectID], isPlaying: Bool, isCapturingInput: Bool)] = [:]

        let liveObjectIDs = Set(Self.processObjectIDs())
        // Drop listeners bound to process objects the HAL no longer lists.
        for objectID in observedObjects.keys where !liveObjectIDs.contains(objectID) {
            unobserve(objectID)
        }

        for objectID in Self.processObjectIDs() {
            observeRunningOutput(of: objectID)

            let pid = Self.pidProperty(objectID)
            guard let owner = Self.owningApplication(pid: pid, objectID: objectID),
                  !excludedBundleIDs.contains(owner.bundleID) else { continue }

            let isPlaying = Self.boolProperty(objectID, kAudioProcessPropertyIsRunningOutput)

            // A shared media process is only worth a channel while it is
            // actually carrying something.
            if owner.isShared && !isPlaying { continue }
            let isCapturing = Self.boolProperty(objectID, kAudioProcessPropertyIsRunningInput)
            if var existing = grouped[owner.bundleID] {
                existing.objectIDs.append(objectID)
                existing.isPlaying = existing.isPlaying || isPlaying
                existing.isCapturingInput = existing.isCapturingInput || isCapturing
                grouped[owner.bundleID] = existing
            } else {
                grouped[owner.bundleID] = (owner.name, [objectID], isPlaying, isCapturing)
            }
        }

        var discovered = grouped.map { bundleID, value in
            AudioProcess(
                objectIDs: value.objectIDs.sorted(),
                bundleID: bundleID,
                name: value.name,
                isPlaying: value.isPlaying,
                isCapturingInput: value.isCapturingInput
            )
        }
        // Whatever is making sound right now belongs at the top: that is the
        // app the user opened MixPill to reach. Alphabetical within each
        // group keeps the order stable enough to build muscle memory.
        discovered.sort { left, right in
            if left.isPlaying != right.isPlaying { return left.isPlaying }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

        guard discovered != processes else { return }
        processes = discovered
        onProcessesChanged?(discovered)
    }

    /// Resolves the application a given audio process belongs to, or nil
    /// if it belongs to none.
    ///
    /// The HAL only tells us a process's own bundle id, which for a helper
    /// is the helper's — `com.google.Chrome.helper`, not
    /// `com.google.Chrome`. Walking the executable path up to the
    /// outermost `.app` wrapper recovers the real owner, because helpers
    /// live nested inside their application's bundle.
    ///
    /// Anything that does not resolve to an application the user could
    /// point at in the Dock — daemons, agents, system XPC services — is
    /// deliberately dropped. They must not appear in the mixer, and they
    /// must not be tapped: a tap mutes what it captures, and muting
    /// `systemsoundserverd` would silence system alerts.
    private static func owningApplication(pid: pid_t, objectID: AudioObjectID) -> Owner? {
        guard pid > 0 else { return nil }

        if let bundle = outermostApplicationBundle(forPID: pid),
           let bundleID = bundle.bundleIdentifier,
           isUserFacing(bundleID: bundleID) {
            return Owner(bundleID: bundleID, name: displayName(of: bundle, bundleID: bundleID), isShared: false)
        }

        let ownBundleID = stringProperty(objectID, kAudioProcessPropertyBundleID)

        // Fall back to the process's own identity — covers a plain,
        // single-process application whose path we could not read.
        if let bundleID = ownBundleID, !bundleID.isEmpty, isUserFacing(bundleID: bundleID) {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? bundleID.components(separatedBy: ".").last
                ?? bundleID
            return Owner(bundleID: bundleID, name: name, isShared: false)
        }

        // Shared media processes: audio that belongs to a real app but is
        // played by a system service on its behalf.
        if let bundleID = ownBundleID,
           sharedMediaProcessIDs.contains(bundleID),
           let name = sharedMediaName(for: bundleID) {
            return Owner(bundleID: bundleID, name: name, isShared: true)
        }

        return nil
    }

    struct Owner {
        let bundleID: String
        let name: String
        /// True for a process that plays on behalf of other apps and cannot
        /// be attributed to one of them.
        let isShared: Bool
    }

    /// Audio that no public API can attribute to the app it belongs to.
    ///
    /// Safari plays through WebKit's GPU process, which lives inside
    /// WebKit.framework rather than Safari.app and is parented to launchd,
    /// so neither the bundle path nor the process tree leads back to
    /// Safari. It is also genuinely shared: any WKWebView host feeds the
    /// same process.
    ///
    /// Rather than leave the Mac's default browser silently uncontrollable,
    /// it gets a channel under a name that says what it actually is. These
    /// entries appear only while they are playing, so the list does not
    /// carry a permanent "Web Content" row nobody asked for.
    private static let sharedMediaProcessIDs: Set<String> = ["com.apple.WebKit.GPU"]

    private static func sharedMediaName(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.WebKit.GPU":
            // Name it for Safari when Safari is the obvious owner, and
            // honestly when it is not.
            let safariRunning = !NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty
            return safariRunning ? "Safari" : "Web Content"
        default:
            return nil
        }
    }

    /// True when some running instance of this bundle is an ordinary app
    /// with a Dock presence.
    private static func isUserFacing(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.activationPolicy == .regular }
    }

    /// The outermost `.app` wrapper containing this process's executable.
    /// "Outermost" is the point: a helper sits inside
    /// `Chrome.app/Contents/Frameworks/…/Chrome Helper.app`, and the
    /// innermost match would just give us the helper again.
    private static func outermostApplicationBundle(forPID pid: pid_t) -> Bundle? {
        var pathBuffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return nil }

        let path = String(decoding: pathBuffer[0..<Int(length)], as: UTF8.self)
        var url = URL(fileURLWithPath: path)
        var outermost: URL?
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" { outermost = url }
            url = url.deletingLastPathComponent()
        }
        guard let outermost else { return nil }
        return Bundle(url: outermost)
    }

    private static func displayName(of bundle: Bundle, bundleID: String) -> String {
        for key in ["CFBundleDisplayName", kCFBundleNameKey as String] {
            if let name = bundle.object(forInfoDictionaryKey: key) as? String, !name.isEmpty {
                return name
            }
        }
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.activationPolicy == .regular })?.localizedName {
            return name
        }
        return bundle.bundleURL.deletingPathExtension().lastPathComponent
    }

    /// Watches one process for playback starting or stopping, so the list
    /// updates the moment audio begins rather than on the next sweep.
    private func observeRunningOutput(of objectID: AudioObjectID) {
        guard observedObjects[objectID] == nil else { return }
        var blocks: [AudioObjectPropertyListenerBlock] = []
        for selector in Self.observedSelectors {
            var address = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.refreshLocked()
            }
            guard AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block) == noErr else { continue }
            blocks.append(block)
        }
        observedObjects[objectID] = blocks
    }

    /// Takes the listeners back off a process object that has gone away.
    private func unobserve(_ objectID: AudioObjectID) {
        guard let blocks = observedObjects.removeValue(forKey: objectID) else { return }
        for (index, selector) in Self.observedSelectors.enumerated() where index < blocks.count {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, blocks[index])
        }
    }


    // MARK: - HAL property helpers

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func processObjectIDs() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    static func stringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    static func boolProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    static func pidProperty(_ objectID: AudioObjectID) -> pid_t {
        var address = Self.address(kAudioProcessPropertyPID)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var value: pid_t = -1
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return -1 }
        return value
    }
}

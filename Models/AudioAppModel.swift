import Foundation
import AppKit

public struct AudioAppModel: Identifiable, Hashable, @unchecked Sendable {
    public let id: String // Bundle Identifier
    public let name: String
    public let icon: NSImage?
    public var volume: Float // 0.0 to 1.0
    public var isMuted: Bool
    public var audioLevel: Float // 0.0 to 1.0 (RMS)
    public var peakLevel: Float // 0.0 to 1.0 (true peak)
    /// Sending audio to an output device right now, as reported by the HAL.
    public var isPlaying: Bool
    /// Holding the microphone right now — shown so it is obvious why other
    /// apps just ducked.
    public var isCapturingInput: Bool

    public init(id: String, name: String, icon: NSImage?, volume: Float = Constants.Audio.defaultVolume, isMuted: Bool = Constants.Audio.defaultMuted, audioLevel: Float = 0.0, peakLevel: Float = 0.0, isPlaying: Bool = false, isCapturingInput: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.volume = volume
        self.isMuted = isMuted
        self.audioLevel = audioLevel
        self.peakLevel = peakLevel
        self.isPlaying = isPlaying
        self.isCapturingInput = isCapturingInput
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: AudioAppModel, rhs: AudioAppModel) -> Bool {
        return lhs.id == rhs.id
    }
}

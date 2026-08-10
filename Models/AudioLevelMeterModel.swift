import Foundation

public struct AudioLevelMeterModel: Equatable {
    public var peakLevel: Float // Max volume in recent buffer
    public var rmsLevel: Float  // Root mean square (average perceived volume)
    
    public init(peakLevel: Float = 0.0, rmsLevel: Float = 0.0) {
        self.peakLevel = max(0.0, min(1.0, peakLevel))
        self.rmsLevel = max(0.0, min(1.0, rmsLevel))
    }
}

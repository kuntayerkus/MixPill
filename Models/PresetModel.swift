import Foundation

public struct PresetModel: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var appVolumes: [String: Float] // BundleID : Volume (0.0 - 1.0)
    public var appMutes: [String: Bool]    // BundleID : isMuted
    
    public init(id: UUID = UUID(), name: String, appVolumes: [String: Float] = [:], appMutes: [String: Bool] = [:]) {
        self.id = id
        self.name = name
        self.appVolumes = appVolumes
        self.appMutes = appMutes
    }
}

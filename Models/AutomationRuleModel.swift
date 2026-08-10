import Foundation

/// An automation rule that applies a preset when a specific application
/// launches (e.g. "When Spotify opens, switch to the Music preset").
public struct AutomationRuleModel: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var triggerAppBundleID: String
    public var triggerAppName: String
    public var presetID: UUID?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        triggerAppBundleID: String,
        triggerAppName: String,
        presetID: UUID? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.triggerAppBundleID = triggerAppBundleID
        self.triggerAppName = triggerAppName
        self.presetID = presetID
        self.isEnabled = isEnabled
    }
}

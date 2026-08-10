import Foundation
import ServiceManagement

/// Login item management via the modern SMAppService API (macOS 13+).
@MainActor
public enum LaunchAtLoginService {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("LaunchAtLoginService: failed to update login item: \(error)")
        }
    }
}

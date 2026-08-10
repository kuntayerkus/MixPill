import SwiftUI

@main
struct MixPillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // A custom template glyph rather than a stock SF Symbol: it is the
        // app's own mark, and the menu bar is the only surface most people
        // ever see MixPill on.
        MenuBarExtra("MixPill", image: "MenuBarIcon") {
            MenuBarView()
                .environment(appDelegate.permissionManager)
                .environment(appDelegate.discoveryService)
                .environment(appDelegate.presetManager)
                .environment(appDelegate.coreBridge)
        }
        .menuBarExtraStyle(.window)
    }
}

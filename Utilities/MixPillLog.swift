import Foundation
import os

/// Diagnostic logging for the MixPill interface process.
///
/// The core service has had `MixPillCoreLog` for a while; the app target
/// had nothing, so seven `print` calls carried the only record of a preset
/// failing to save, a login item failing to register or an automation rule
/// firing — straight to a stdout that a GUI app launched from Finder does
/// not have. When somebody says "my presets don't stick" there was no
/// trace to look at.
///
///     log stream --predicate 'subsystem == "com.mixpill.app"' --level debug
///
/// Messages are interpolated `.public` for the same reason the core's are:
/// these are diagnostics — bundle ids, error codes, preset names — never
/// audio and never anything the user typed into a document.
public enum MixPillLog {
    private static let logger = Logger(subsystem: "com.mixpill.app", category: "app")

    public static func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

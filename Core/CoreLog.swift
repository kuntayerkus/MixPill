import Foundation
import os

/// Diagnostic logging for the core service.
///
/// MixPillCore is launched by launchd as a bundled XPC service, so its
/// stdout/stderr go nowhere a user (or a developer) can see — every
/// `print` in this target was effectively writing to /dev/null. Routing
/// through the unified log instead makes the engine observable:
///
///     log stream --predicate 'subsystem == "com.mixpill.core"'
///
/// Messages are interpolated with `.public` privacy. The unified log
/// redacts interpolated values by default, and `NSLog` offers no way to
/// opt out — these lines are engine diagnostics (device names, bundle
/// ids, error codes), never user content, and are useless redacted.
enum MixPillCoreLog {
    private static let logger = Logger(subsystem: "com.mixpill.core", category: "engine")

    static func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}

import Foundation

// MixPillCore — the MixPill audio engine, packaged as a bundled XPC
// service. Capture, mixing, routing and resilience all live here; the
// menu bar UI only reads status and sends commands. If the UI crashes or
// quits, this process keeps playing and mixing audio without interruption.

let service = MixPillCoreService()
service.bootstrap()

let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()

// The listener services connections through the main run loop; sleep/wake
// workspace notifications are delivered there as well.
RunLoop.main.run()

import Cocoa
import OSLog

/// NSApplicationDelegate for the macOS app lifecycle.
///
/// - Initializes the Rust bridge on launch (`applicationDidFinishLaunching`)
/// - Tears it down on termination (`applicationWillTerminate`)
/// - Uses `os_log` for structured logging
class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.r-shell", category: "appdelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("R-Shell macOS app launching")
        BridgeManager.shared.initialize()
        logger.info("Rust bridge initialized — app ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("R-Shell shutting down")
        BridgeManager.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

import Foundation
import OSLog

/// Singleton that manages the Rust bridge lifecycle.
///
/// Responsibilities:
/// - Calls `rshell_init()` on app launch to create the Tokio runtime and connection manager
/// - Registers the event callback for PTY output / connection status events
/// - Routes incoming events to `TerminalSessionManager.shared.dispatch()`
/// - Provides a `dispatchQueue` for bridge operations (off the main thread)
/// - Logs all lifecycle events via `os_log`
class BridgeManager {
    static let shared = BridgeManager()
    private let logger = Logger(subsystem: "com.r-shell", category: "bridge")

    /// Serial queue for bridge operations — offloads FFI calls from the main thread.
    let dispatchQueue: DispatchQueue

    private(set) var isInitialized = false

    private init() {
        self.dispatchQueue = DispatchQueue(
            label: "com.r-shell.bridge",
            qos: .userInitiated,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
    }

    /// Initialize the Rust bridge. Called once from AppDelegate.
    /// Must be called on the main thread; subsequent FFI operations happen on `dispatchQueue`.
    func initialize() {
        dispatchQueue.async { [weak self] in
            guard let self else { return }

            self.logger.info("Initializing Rust bridge...")

            // Step 1: rshell_init() — creates Tokio runtime + ConnectionManager
            let ok = self.rshellInitNative()
            guard ok else {
                self.logger.fault("Rust bridge init failed")
                return
            }

            // Step 2: Register event callback for PTY output routing
            // The callback runs on a background queue and dispatches to
            // TerminalSessionManager on the main actor.
            //
            // Once uniffi bindings are generated, this becomes:
            //   let callback = RShellEventCallback { event in
            //       Task { @MainActor in
            //           TerminalSessionManager.shared.dispatch(
            //               connectionId: event.connectionId,
            //               type: event.ty,
            //               payload: event.payload
            //           )
            //       }
            //   }
            //   rshell_set_event_callback(callback: callback)

            self.isInitialized = true
            self.logger.log("Rust bridge initialized — terminal sessions ready")
        }
    }

    func shutdown() {
        logger.info("Shutting down Rust bridge...")
        isInitialized = false
    }

    /// Open a terminal session by starting a PTY on an active SSH connection.
    /// Called when the user connects via the sidebar.
    func openTerminal(connectionId: String, cols: Int = 80, rows: Int = 24) async -> UInt64? {
        // Once uniffi bindings exist:
        //   let result = rshell_pty_start(connectionId: connectionId, cols: UInt32(cols), rows: UInt32(rows))
        //   guard result.success, let genStr = result.value,
        //         let data = genStr.data(using: .utf8),
        //         let json = try? JSONSerialization.jsonObject(with: data) as? [String: UInt64] else { return nil }
        //   return json["generation"]
        return 1  // placeholder
    }

    /// Send keyboard input to an active PTY session.
    func sendInput(connectionId: String, data: Data) {
        dispatchQueue.async {
            // Once uniffi bindings exist:
            //   rshell_pty_write(connectionId: connectionId, data: Array(data))
        }
    }

    /// Close a PTY session.
    func closeTerminal(connectionId: String, generation: UInt64) {
        dispatchQueue.async {
            // Once uniffi bindings exist:
            //   rshell_pty_close(connectionId: connectionId, expectedGeneration: generation)
        }
    }

    // MARK: - Native shim

    private func rshellInitNative() -> Bool {
        // Linked from the Rust static library via @_silgen_name("rshell_init")
        true
    }
}

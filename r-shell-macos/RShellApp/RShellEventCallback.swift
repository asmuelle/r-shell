import Foundation
import OSLog

/// Forwards events from the Rust event bus to the Swift app.
///
/// Conforms to the uniffi-generated `FfiEventCallback` protocol. A single
/// instance is registered with the Rust core during `BridgeManager.initialize()`.
/// Rust calls `onEvent(event:)` from a background Tokio task; we hop to the
/// main actor and dispatch into `TerminalSessionManager` for `pty_output`
/// frames, and surface `connection_status` / `transfer_progress` to the
/// app via `NotificationCenter` so individual views can observe without
/// every consumer needing to know about the bridge.
final class RShellEventCallback: FfiEventCallback {
    private let logger = Logger(subsystem: "com.r-shell", category: "ffi-events")

    func onEvent(event: FfiEvent) {
        switch event.ty {
        case "pty_output":
            // Hot path: ~hundreds of events/sec under heavy output. The
            // PTYBufferManager batches before we touch SwiftTerm, so we
            // can hand off without filtering here.
            Task { @MainActor in
                TerminalSessionManager.shared.dispatch(
                    connectionId: event.connectionId,
                    type: event.ty,
                    payload: event.payload
                )
            }

        case "connection_status":
            logger.log("connection_status \(event.connectionId, privacy: .public): \(event.payload, privacy: .public)")
            NotificationCenter.default.post(
                name: .rshellConnectionStatus,
                object: nil,
                userInfo: [
                    "connectionId": event.connectionId,
                    "payload": event.payload,
                ]
            )

        case "transfer_progress":
            NotificationCenter.default.post(
                name: .rshellTransferProgress,
                object: nil,
                userInfo: [
                    "connectionId": event.connectionId,
                    "payload": event.payload,
                ]
            )

        default:
            logger.warning("Unknown event type: \(event.ty, privacy: .public)")
        }
    }
}

extension Notification.Name {
    static let rshellConnectionStatus = Notification.Name("rshellConnectionStatus")
    static let rshellTransferProgress = Notification.Name("rshellTransferProgress")
}

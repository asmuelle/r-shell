import Foundation
import OSLog
import RShellMacOS

/// Manages all active terminal sessions. Routes events from the global
/// Rust event-bus callback to the correct `PTYBufferManager` for each
/// connection.
///
/// IME handling: SwiftTerm's `TerminalView` handles IME composition
/// internally. The `send(source:data:)` delegate callback only fires
/// for committed text — partial composition state never leaks into
/// the PTY stream.
@MainActor
final class TerminalSessionManager {
    static let shared = TerminalSessionManager()
    private let logger = Logger(subsystem: "com.r-shell", category: "terminal-session")

    struct Session {
        let connectionId: String
        let ptyGeneration: UInt64
        let bufferManager: PTYBufferManager
        var isPaused: Bool = false
    }

    private var sessions: [String: Session] = [:]

    /// Event payloads that arrived before the matching `TerminalView` ran
    /// `registerSession`. Drained into the buffer manager when registration
    /// completes. Capped to avoid unbounded growth if the user dismisses
    /// the connect flow without ever materialising the terminal view.
    private var pendingPayloads: [String: [Data]] = [:]
    private static let maxPendingBytesPerConnection = 1 << 20  // 1 MiB

    private init() {}

    // MARK: - Session lifecycle

    func registerSession(connectionId: String, generation: UInt64, onFlush: @escaping (Data) -> Void) {
        let bufferManager = PTYBufferManager(onFlush: onFlush)
        let session = Session(
            connectionId: connectionId,
            ptyGeneration: generation,
            bufferManager: bufferManager
        )
        sessions[connectionId] = session
        logger.info("Terminal session registered: \(connectionId, privacy: .public) gen=\(generation)")

        // Drain any payloads that arrived during the gap between
        // `rshell_pty_start` returning and SwiftUI materialising the
        // TerminalView. Without this, the shell prompt / vim opening
        // screen / etc. is silently lost.
        if let pending = pendingPayloads.removeValue(forKey: connectionId), !pending.isEmpty {
            logger.info("Replaying \(pending.count) buffered chunks for \(connectionId, privacy: .public)")
            for data in pending {
                bufferManager.append(data)
            }
        }
    }

    func unregisterSession(connectionId: String) {
        sessions[connectionId]?.bufferManager.reset()
        sessions.removeValue(forKey: connectionId)
        // Clear any stale pending payloads so we don't replay them onto a
        // future session for the same connection id.
        pendingPayloads.removeValue(forKey: connectionId)
        logger.info("Terminal session unregistered: \(connectionId, privacy: .public)")
    }

    func session(for connectionId: String) -> Session? {
        sessions[connectionId]
    }

    func pauseSession(connectionId: String) {
        sessions[connectionId]?.isPaused = true
    }

    func resumeSession(connectionId: String) {
        sessions[connectionId]?.isPaused = false
    }

    // MARK: - Dispatch from event bus

    /// Decode a `pty_output` payload and append it to the connection's
    /// buffer manager (which adaptively flushes to the terminal view).
    ///
    /// The Rust core encodes the payload as `serde_json::to_string(&data)`
    /// where `data: Vec<u8>` — i.e., a JSON array literal like `"[72,101,108,108,111]"`.
    /// We parse the *string* as UTF-8, then decode the JSON array of bytes.
    func dispatch(connectionId: String, type: String, payload: String) {
        guard type == "pty_output" else { return }

        guard let data = PtyPayloadDecoder.decode(payload) else {
            logger.error("Failed to decode pty_output payload (\(payload.prefix(60), privacy: .public)…)")
            return
        }

        if let session = sessions[connectionId] {
            guard !session.isPaused else { return }
            session.bufferManager.append(data)
        } else {
            // Race: PTY started before the SwiftUI view registered the
            // session. Buffer until registration. Bound the buffer so a
            // forgotten connection can't grow without limit.
            var queue = pendingPayloads[connectionId] ?? []
            let pendingBytes = queue.reduce(0) { $0 + $1.count }
            if pendingBytes + data.count <= Self.maxPendingBytesPerConnection {
                queue.append(data)
                pendingPayloads[connectionId] = queue
            } else {
                logger.warning("pendingPayloads cap reached for \(connectionId, privacy: .public); dropping early output")
            }
        }
    }

    // MARK: - Send input

    /// Forward keyboard input to the Rust PTY. Routed through `BridgeManager`
    /// which serializes onto its own queue.
    func sendInput(connectionId: String, data: Data) {
        guard sessions[connectionId] != nil else { return }
        BridgeManager.shared.sendInput(connectionId: connectionId, data: data)
    }
}

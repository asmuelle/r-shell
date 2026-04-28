import Foundation
import OSLog

/// Manages all active terminal sessions. Routes events from the global
/// Rust event bus callback to the correct `PTYBufferManager` for each
/// connection.
///
/// IME handling: SwiftTerm's `TerminalView` handles IME composition
/// internally through its NSView. The `send(source:data:)` delegate
/// callback only fires for committed text, so there is no risk of
/// partial composition state leaking into the PTY stream. Dead keys
/// (e.g. Option-E for ´ accent) are composed by the system and the
/// final character is sent after the second keypress — no special
/// handling needed.
@MainActor
class TerminalSessionManager {
    static let shared = TerminalSessionManager()
    private let logger = Logger(subsystem: "com.r-shell", category: "terminal-session")

    struct Session {
        let connectionId: String
        let ptyGeneration: UInt64
        let bufferManager: PTYBufferManager
        var isPaused: Bool = false
    }

    private var sessions: [String: Session] = [:]
    private let inputQueue = DispatchQueue(label: "com.r-shell.pty-input", qos: .userInitiated)

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
        logger.info("Terminal session registered: \(connectionId)")
    }

    func unregisterSession(connectionId: String) {
        sessions[connectionId]?.bufferManager.reset()
        sessions.removeValue(forKey: connectionId)
        logger.info("Terminal session unregistered: \(connectionId)")
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

    func dispatch(connectionId: String, type: String, payload: String) {
        guard type == "pty_output", let session = sessions[connectionId] else { return }
        guard !session.isPaused else { return }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let bytes = try? JSONDecoder().decode([UInt8].self, from: data) else {
            return
        }
        session.bufferManager.append(Data(bytes))
    }

    // MARK: - Send input

    func sendInput(connectionId: String, data: Data) {
        guard sessions[connectionId] != nil else { return }
        inputQueue.async { [connectionId] in
            // rshell_pty_write(connectionId: connectionId, data: Array(data))
        }
    }
}

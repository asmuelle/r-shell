import Foundation
import OSLog
import RShellMacOS

/// Singleton that manages the Rust bridge lifecycle and exposes a
/// thin Swift API over the uniffi-generated FFI surface.
///
/// Responsibilities:
/// - `initialize()`: calls `rshellInit()` and registers the event callback.
/// - `connect(...)`: maps a `ConnectionProfile` to `FfiConnectConfig` and
///   calls `rshellConnect`.
/// - `openTerminal(...)`: starts a PTY and parses the generation counter.
/// - `sendInput`, `resize`, `closeTerminal`: thin pass-throughs.
///
/// All FFI calls run on `dispatchQueue` (a serial background queue) to
/// keep the main thread responsive — the Rust side blocks on its Tokio
/// runtime, so calling from main can stall the UI.
final class BridgeManager {
    static let shared = BridgeManager()
    private let logger = Logger(subsystem: "com.r-shell", category: "bridge")

    /// Serial queue for FFI calls — keeps blocking Rust calls off the main thread.
    let dispatchQueue: DispatchQueue

    private(set) var isInitialized = false

    /// Strong reference — Rust holds a callback handle but we keep a
    /// Swift reference too, so the object isn't deallocated while Rust
    /// is still calling into it.
    private var eventCallback: RShellEventCallback?

    private init() {
        self.dispatchQueue = DispatchQueue(
            label: "com.r-shell.bridge",
            qos: .userInitiated,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
    }

    // MARK: - Lifecycle

    /// Initialize the Rust bridge. Call once from `AppDelegate`. Idempotent
    /// on the Rust side, but we guard against double-init in Swift.
    func initialize() {
        dispatchQueue.async { [weak self] in
            guard let self else { return }

            if self.isInitialized {
                self.logger.warning("BridgeManager.initialize() called twice; ignoring")
                return
            }

            self.logger.info("Initializing Rust bridge")

            guard rshellInit() else {
                self.logger.fault("rshellInit() returned false")
                return
            }

            // Register a single event callback for the lifetime of the app.
            // PTY output, connection status changes, and transfer progress
            // all flow through this callback.
            let callback = RShellEventCallback()
            rshellSetEventCallback(callback: callback)
            self.eventCallback = callback

            self.isInitialized = true
            self.logger.log("Rust bridge initialized")
        }
    }

    func shutdown() {
        logger.info("Shutting down Rust bridge")
        isInitialized = false
        // The Rust runtime is dropped on process exit; nothing else to do.
    }

    // MARK: - Connection

    /// Map a stored `ConnectionProfile` to an FFI config and connect.
    ///
    /// `sessionId` lets the caller open multiple PTY sessions to the same
    /// `(user, host, port)` triple — each tab passes its own UUID-derived
    /// suffix and r-shell-core keys the connections separately. Without
    /// it, opening the same profile twice would replace the first PTY
    /// (the connection-manager `HashMap` key would collide).
    ///
    /// Returns the canonical connection id Rust assigned (`"user@host:port"`
    /// or `"user@host:port#sessionId"`), which subsequent `openTerminal`,
    /// `sendInput`, `closeTerminal` calls must reuse verbatim.
    func connect(
        profile: ConnectionProfile,
        password: String?,
        keyPath: String? = nil,
        passphrase: String? = nil,
        sessionId: String? = nil
    ) async -> Result<String, BridgeError> {
        let config = FfiConnectConfig(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: password,
            keyPath: keyPath ?? profile.privateKeyPath,
            passphrase: passphrase,
            sessionId: sessionId
        )

        return await withCheckedContinuation { cont in
            dispatchQueue.async { [weak self] in
                guard let self else { return }

                do {
                    let connectionId = try rshellConnect(config: config)
                    self.logger.log("Connected: \(connectionId, privacy: .public)")
                    cont.resume(returning: .success(connectionId))
                } catch let err as ConnectError {
                    self.logger.error("Connect failed: \(String(describing: err), privacy: .public)")
                    cont.resume(returning: .failure(BridgeError.from(err)))
                } catch {
                    self.logger.error("Connect failed (unexpected): \(error.localizedDescription, privacy: .public)")
                    cont.resume(returning: .failure(.other(error.localizedDescription)))
                }
            }
        }
    }

    func disconnect(connectionId: String) {
        dispatchQueue.async {
            _ = rshellDisconnect(connectionId: connectionId)
        }
    }

    // MARK: - PTY

    /// Start a PTY session. Returns the `generation` counter so the caller
    /// can use it for `closeTerminal` and stale-close protection.
    func openTerminal(connectionId: String, cols: Int = 80, rows: Int = 24) async -> UInt64? {
        await withCheckedContinuation { cont in
            dispatchQueue.async { [weak self] in
                guard let self else { return }

                let result = rshellPtyStart(
                    connectionId: connectionId,
                    cols: UInt32(cols),
                    rows: UInt32(rows)
                )
                guard result.success else {
                    self.logger.error("PTY start failed: \(result.error ?? "?", privacy: .public)")
                    cont.resume(returning: nil)
                    return
                }

                // Rust returns `{"generation": N}` as a JSON string in `value`.
                guard
                    let valueStr = result.value,
                    let data = valueStr.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let gen = json["generation"] as? UInt64
                else {
                    self.logger.warning("Could not parse PTY generation; defaulting to 1")
                    cont.resume(returning: 1)
                    return
                }

                self.logger.log("PTY \(connectionId, privacy: .public) generation=\(gen)")
                cont.resume(returning: gen)
            }
        }
    }

    /// Send keyboard input to a running PTY.
    ///
    /// Coalesced through a per-connection batcher so a paste of N bytes
    /// produces one FFI call (or a handful) instead of one per byte.
    /// Single keystrokes still flush within ~16 ms so latency is
    /// imperceptible.
    func sendInput(connectionId: String, data: Data) {
        dispatchQueue.async { [weak self] in
            guard let self else { return }
            self.writeBatcher(for: connectionId).append(data)
        }
    }

    /// Flush any pending writes for a connection (used on close so we
    /// don't lose the trailing bytes of a final command).
    func flushPendingInput(connectionId: String) {
        dispatchQueue.async { [weak self] in
            self?.writeBatchers.removeValue(forKey: connectionId)?.flushNow()
        }
    }

    // MARK: - Write batching

    private var writeBatchers: [String: WriteBatcher] = [:]

    private func writeBatcher(for connectionId: String) -> WriteBatcher {
        if let existing = writeBatchers[connectionId] { return existing }
        let new = WriteBatcher(connectionId: connectionId, queue: dispatchQueue)
        writeBatchers[connectionId] = new
        return new
    }

    /// Resize a running PTY. Currently called only from explicit resize
    /// triggers; per-frame resize is deferred to Sprint 8 with debouncing.
    func resize(connectionId: String, cols: Int, rows: Int) {
        dispatchQueue.async {
            _ = rshellPtyResize(
                connectionId: connectionId,
                cols: UInt32(cols),
                rows: UInt32(rows)
            )
        }
    }

    func closeTerminal(connectionId: String, generation: UInt64) {
        dispatchQueue.async { [weak self] in
            // Flush any pending input before tearing down — bytes typed
            // within the 16 ms batching window before Cmd+W would
            // otherwise be lost.
            self?.writeBatchers.removeValue(forKey: connectionId)?.flushNow()
            _ = rshellPtyClose(connectionId: connectionId, expectedGeneration: generation)
        }
    }
}

// MARK: - Errors

/// Swift-side mirror of `ConnectError` plus the non-connect error cases.
/// Keeping this Swift-typed (rather than passing `ConnectError` through
/// directly) means the rest of the app doesn't have to depend on the
/// uniffi-generated module.
enum BridgeError: Error, LocalizedError {
    case configInvalid(String)
    case passphraseRequired(String)
    case authFailed(String)
    case hostKeyMismatch(String)
    case network(String)
    case ptyStart(String)
    case notInitialized
    case other(String)

    var errorDescription: String? {
        switch self {
        case .configInvalid(let msg):     return "Invalid configuration: \(msg)"
        case .passphraseRequired(let msg): return "Key passphrase required: \(msg)"
        case .authFailed(let msg):        return "Authentication failed: \(msg)"
        case .hostKeyMismatch(let msg):   return "Host key mismatch: \(msg)"
        case .network(let msg):           return "Network error: \(msg)"
        case .ptyStart(let msg):          return "Failed to start terminal: \(msg)"
        case .notInitialized:             return "Rust bridge not initialized"
        case .other(let msg):             return msg
        }
    }

    static func from(_ err: ConnectError) -> BridgeError {
        // uniffi 0.28 generates PascalCase Swift enum cases from the Rust
        // variant names — keep these in lock-step if a variant is added.
        switch err {
        case .ConfigInvalid(let detail):     return .configInvalid(detail)
        case .PassphraseRequired(let detail): return .passphraseRequired(detail)
        case .AuthFailed(let detail):        return .authFailed(detail)
        case .HostKeyMismatch(let detail):   return .hostKeyMismatch(detail)
        case .Network(let detail):           return .network(detail)
        case .Other(let detail):             return .other(detail)
        }
    }
}

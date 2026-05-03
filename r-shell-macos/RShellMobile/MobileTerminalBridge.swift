import Foundation

final class MobileTerminalBridge {
    static let shared = MobileTerminalBridge()

    private let queue = DispatchQueue(
        label: "com.r-shell.mobile.terminal-bridge",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private var writeBatchers: [String: MobileWriteBatcher] = [:]

    private init() {}

    func openTerminal(connectionId: String, cols: Int = 80, rows: Int = 24) async throws -> UInt64 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result = rshellPtyStart(
                    connectionId: connectionId,
                    cols: UInt32(cols),
                    rows: UInt32(rows)
                )

                do {
                    let payload = try result.requireValue(operation: "PTY start")
                    guard
                        let data = payload.data(using: .utf8),
                        let decoded = try? JSONDecoder().decode(MobilePtyStartPayload.self, from: data)
                    else {
                        throw MobileTerminalBridgeError.malformedResponse("Rust returned an invalid PTY generation payload.")
                    }
                    continuation.resume(returning: decoded.generation)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func sendInput(connectionId: String, data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.writeBatcher(for: connectionId).append(data)
        }
    }

    func resize(connectionId: String, cols: Int, rows: Int) {
        queue.async {
            _ = rshellPtyResize(
                connectionId: connectionId,
                cols: UInt32(cols),
                rows: UInt32(rows)
            )
        }
    }

    func closeTerminal(connectionId: String, generation: UInt64) {
        queue.async { [weak self] in
            self?.writeBatchers.removeValue(forKey: connectionId)?.flushNow()
            _ = rshellPtyClose(connectionId: connectionId, expectedGeneration: generation)
        }
    }

    private func writeBatcher(for connectionId: String) -> MobileWriteBatcher {
        if let existing = writeBatchers[connectionId] { return existing }
        let new = MobileWriteBatcher(connectionId: connectionId, queue: queue)
        writeBatchers[connectionId] = new
        return new
    }
}

private struct MobilePtyStartPayload: Decodable {
    let generation: UInt64
}

private extension FfiResult {
    func requireValue(operation: String) throws -> String {
        guard success else {
            throw MobileTerminalBridgeError.operationFailed(
                operation,
                error ?? "\(operation) failed without an error message."
            )
        }
        guard let value else {
            throw MobileTerminalBridgeError.malformedResponse("\(operation) succeeded without a return value.")
        }
        return value
    }
}

enum MobileTerminalBridgeError: Error, LocalizedError {
    case operationFailed(String, String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let operation, let detail):
            return "\(operation) failed: \(detail)"
        case .malformedResponse(let detail):
            return detail
        }
    }
}

private final class MobileWriteBatcher {
    private let connectionId: String
    private let queue: DispatchQueue
    private var pending = Data()
    private var pendingFlush: DispatchWorkItem?

    private static let flushDelay: TimeInterval = 0.016
    private static let flushThreshold = 4096

    init(connectionId: String, queue: DispatchQueue) {
        self.connectionId = connectionId
        self.queue = queue
    }

    func append(_ data: Data) {
        pending.append(data)

        if pending.count >= Self.flushThreshold {
            flushNow()
            return
        }

        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushNow()
        }
        pendingFlush = work
        queue.asyncAfter(deadline: .now() + Self.flushDelay, execute: work)
    }

    func flushNow() {
        pendingFlush?.cancel()
        pendingFlush = nil

        guard !pending.isEmpty else { return }
        let chunk = pending
        pending = Data()
        _ = rshellPtyWrite(connectionId: connectionId, data: chunk)
    }
}

import Foundation

struct MobilePtyOutputFrame: Equatable, Sendable {
    let generation: UInt64
    let data: Data
}

enum MobilePtyPayloadDecoder {
    static func decode(_ payload: String) -> MobilePtyOutputFrame? {
        guard let utf8 = payload.data(using: .utf8) else { return nil }

        struct Wire: Decodable {
            let generation: UInt64
            let bytes: [UInt8]
        }

        guard let wire = try? JSONDecoder().decode(Wire.self, from: utf8) else {
            return nil
        }
        return MobilePtyOutputFrame(generation: wire.generation, data: Data(wire.bytes))
    }
}

@MainActor
final class MobileTerminalSessionManager {
    static let shared = MobileTerminalSessionManager()

    struct Session {
        let connectionId: String
        let ptyGeneration: UInt64
        let bufferManager: MobilePTYBufferManager
        var isPaused = false
    }

    private var sessions: [String: Session] = [:]
    private var pendingPayloads: [String: [MobilePtyOutputFrame]] = [:]
    private static let maxPendingBytesPerConnection = 1 << 20

    private init() {}

    func registerSession(
        connectionId: String,
        generation: UInt64,
        onFlush: @escaping (Data) -> Void
    ) {
        let bufferManager = MobilePTYBufferManager(onFlush: onFlush)
        sessions[connectionId] = Session(
            connectionId: connectionId,
            ptyGeneration: generation,
            bufferManager: bufferManager
        )

        if let pending = pendingPayloads.removeValue(forKey: connectionId), !pending.isEmpty {
            for frame in pending where frame.generation == generation {
                bufferManager.append(frame.data)
            }
        }
    }

    func unregisterSession(connectionId: String) {
        sessions[connectionId]?.bufferManager.cancel()
        sessions[connectionId]?.bufferManager.reset()
        sessions.removeValue(forKey: connectionId)
        pendingPayloads.removeValue(forKey: connectionId)
    }

    func pauseSession(connectionId: String) {
        sessions[connectionId]?.isPaused = true
    }

    func resumeSession(connectionId: String) {
        sessions[connectionId]?.isPaused = false
    }

    func pauseAllSessions() {
        for connectionId in sessions.keys {
            sessions[connectionId]?.isPaused = true
        }
    }

    func resumeAllSessions() {
        for connectionId in sessions.keys {
            sessions[connectionId]?.isPaused = false
        }
    }

    func dispatch(connectionId: String, type: String, payload: String) {
        guard type == "pty_output",
              let frame = MobilePtyPayloadDecoder.decode(payload) else {
            return
        }

        if let session = sessions[connectionId] {
            guard !session.isPaused, frame.generation == session.ptyGeneration else { return }
            session.bufferManager.append(frame.data)
        } else {
            var queue = pendingPayloads[connectionId] ?? []
            let pendingBytes = queue.reduce(0) { $0 + $1.data.count }
            if pendingBytes + frame.data.count <= Self.maxPendingBytesPerConnection {
                queue.append(frame)
                pendingPayloads[connectionId] = queue
            }
        }
    }
}

@MainActor
final class MobilePTYBufferManager {
    private var buffer = Data()
    private var flushTimer: DispatchSourceTimer?
    private let onFlush: (Data) -> Void

    private let threshold = 8 * 1024
    private let interval: DispatchTimeInterval = .milliseconds(16)

    init(onFlush: @escaping (Data) -> Void) {
        self.onFlush = onFlush
    }

    func append(_ data: Data) {
        buffer.append(data)

        if buffer.count >= threshold {
            flush()
            return
        }

        if flushTimer == nil {
            startTimer()
        }
    }

    func flush() {
        cancel()
        guard !buffer.isEmpty else { return }

        let chunk = buffer
        buffer = Data()
        onFlush(chunk)
    }

    func reset() {
        cancel()
        buffer.removeAll()
    }

    func cancel() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.flush()
            }
        }
        timer.resume()
        flushTimer = timer
    }
}

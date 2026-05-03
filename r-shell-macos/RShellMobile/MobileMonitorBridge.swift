import Foundation

final class MobileMonitorBridge {
    static let shared = MobileMonitorBridge()

    private let queue = DispatchQueue(
        label: "com.r-shell.mobile.monitor-bridge",
        qos: .utility,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )

    private init() {}

    func getSystemStats(connectionId: String) async throws -> FfiSystemStats {
        try await run {
            try rshellGetSystemStats(connectionId: connectionId)
        }
    }

    func getProcesses(connectionId: String) async throws -> [FfiProcess] {
        try await run {
            try rshellGetProcesses(connectionId: connectionId)
        }
    }

    func executeCommand(connectionId: String, command: String) async throws -> String {
        let result: FfiResult = try await run {
            rshellExecuteCommand(connectionId: connectionId, command: command)
        }
        guard result.success else {
            throw MobileMonitorBridgeError.commandFailed(
                result.error ?? "Remote command failed without an error message."
            )
        }
        return result.value ?? ""
    }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum MobileMonitorBridgeError: Error, LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            return detail
        }
    }
}

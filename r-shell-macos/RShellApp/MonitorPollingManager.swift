import Foundation
import OSLog
import RShellMacOS

/// Background poller for system monitor, process list, network stats, and logs.
/// Each poll target can be started/stopped independently.
///
/// Once FFI is wired, these call `rshell_execute_command` to run remote scripts.
/// For now, they simulate data to validate the UI.
@MainActor
class MonitorPollingManager: ObservableObject {
    static let shared = MonitorPollingManager()
    private let logger = Logger(subsystem: "com.r-shell", category: "monitor-poll")

    @Published var systemStats = SystemStats.zero
    @Published var networkStats = NetworkStats.zero
    @Published var processes: [RemoteProcessInfo] = []
    @Published var logEntries: [LogEntry] = []

    private var pollTimers: [String: DispatchSourceTimer] = [:]
    private let queue = DispatchQueue(label: "com.r-shell.monitor", qos: .utility)

    private init() {}

    // MARK: - Start/stop polling

    func startPolling(connectionId: String) {
        startSystemPoll(connectionId: connectionId)
        startNetworkPoll(connectionId: connectionId)
        startProcessPoll(connectionId: connectionId)
    }

    func stopPolling(connectionId: String) {
        for key in pollTimers.keys where key.hasPrefix(connectionId) {
            pollTimers[key]?.cancel()
            pollTimers.removeValue(forKey: key)
        }
    }

    // MARK: - System stats (every 3s)

    private func startSystemPoll(connectionId: String) {
        let key = "\(connectionId).system"
        pollTimers[key] = startTimer(interval: 3) { [weak self] in
            // Once FFI: let result = rshell_execute_command(connectionId: connectionId, command: systemScript)
            self?.systemStats = SystemStats.zero  // stub
        }
    }

    // MARK: - Network stats (every 5s)

    private func startNetworkPoll(connectionId: String) {
        let key = "\(connectionId).network"
        pollTimers[key] = startTimer(interval: 5) { [weak self] in
            // stub
        }
    }

    // MARK: - Process list (every 5s)

    private func startProcessPoll(connectionId: String) {
        let key = "\(connectionId).processes"
        pollTimers[key] = startTimer(interval: 5) { [weak self] in
            // stub
        }
    }

    // MARK: - Log tail (manual refresh)

    func tailLog(connectionId: String, path: String, lines: Int = 50) {
        queue.async { [weak self] in
            // Once FFI: call rshell_execute_command with tail command
            Task { @MainActor in
                self?.logEntries = []  // stub
            }
        }
    }

    func searchLog(connectionId: String, path: String, query: String) {
        queue.async { [weak self] in
            // stub
        }
    }

    // MARK: - Timer helper

    private func startTimer(interval: TimeInterval, block: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .seconds(1))
        timer.setEventHandler(handler: block)
        timer.resume()
        return timer
    }
}

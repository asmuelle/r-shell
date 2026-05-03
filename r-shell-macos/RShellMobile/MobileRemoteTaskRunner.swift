import Foundation

final class MobileRemoteTaskRunner {
    static let shared = MobileRemoteTaskRunner()

    private init() {}

    func run(
        connectionId: String,
        title: String,
        command: String,
        risk: MobileTaskRisk = .readOnly
    ) async throws -> MobileRemoteTaskResult {
        let marker = "__MIDNIGHT_SSH_EXIT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let startedAt = Date()
        let wrapped = """
        (
        \(command)
        )
        __midnight_ssh_rc=$?
        printf '\\n\(marker):%s\\n' "$__midnight_ssh_rc"
        exit 0
        """
        let output = try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: wrapped
        )
        let parsed = try parseOutput(output, marker: marker, title: title)
        return MobileRemoteTaskResult(
            title: title,
            command: command,
            risk: risk,
            exitCode: parsed.exitCode,
            output: parsed.output,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    private func parseOutput(
        _ output: String,
        marker: String,
        title: String
    ) throws -> (output: String, exitCode: Int32) {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let markerIndex = lines.lastIndex(where: { $0.hasPrefix("\(marker):") }) else {
            throw MobileRemoteTaskError.missingExitMarker(title)
        }
        let markerLine = lines[markerIndex]
        let rawCode = markerLine.dropFirst(marker.count + 1)
        let exitCode = Int32(rawCode.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        let visibleOutput = lines[..<markerIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (visibleOutput, exitCode)
    }
}

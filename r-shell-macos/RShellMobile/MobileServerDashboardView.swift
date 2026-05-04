import SwiftUI

struct MobileServerDashboardView: View {
    let connectionId: String
    let profileName: String
    let sshPort: UInt16

    @State private var stats: FfiSystemStats?
    @State private var processes: [FfiProcess] = []
    @State private var ufwSummary = MobileUFWProtectionSummary.loading
    @State private var isLoading = false
    @State private var lastUpdated: Date?
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            LazyVGrid(columns: columns, spacing: 10) {
                metricCard(
                    title: "CPU",
                    value: percent(stats?.cpuPercent),
                    detail: "Load \(number(stats?.loadAverage1m))",
                    color: loadColor(stats?.cpuPercent ?? 0)
                )
                metricCard(
                    title: "Memory",
                    value: memoryPercentText,
                    detail: memoryDetail,
                    color: loadColor(memoryPercent)
                )
                metricCard(
                    title: "Swap",
                    value: swapPercentText,
                    detail: swapDetail,
                    color: swapUsed > 0 ? loadColor(swapPercent) : .secondary
                )
                metricCard(
                    title: "Disk",
                    value: diskPercentText,
                    detail: diskDetail,
                    color: loadColor(diskPercent)
                )
                metricCard(
                    title: "Uptime",
                    value: uptimeText,
                    detail: "Host runtime",
                    color: .secondary
                )
                ufwCard
            }

            processSection
            MobileServerDoctorView(
                connectionId: connectionId,
                profileName: profileName,
                sshPort: sshPort
            )
            MobileServiceInspectorView(connectionId: connectionId)
            MobileRunbooksView(connectionId: connectionId)
            MobileDevOpsPanelsView(connectionId: connectionId)
            MobileDiskAnalyzerView(connectionId: connectionId)
            MobileNetworkDiagnosticsView(connectionId: connectionId)
            MobilePackageUpdatesView(connectionId: connectionId)
            MobileRuntimePanelsView(connectionId: connectionId)
            MobileConnectionMapView(connectionId: connectionId)
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: connectionId) {
            await refresh()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Dashboard", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Text(profileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
            .accessibilityLabel("Refresh dashboard")
        }
    }

    private func metricCard(title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var ufwCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ufwColor)
                    .frame(width: 8, height: 8)
                Text("UFW")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(ufwSummary.badgeText)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(ufwColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(ufwSummary.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top Processes")
                    .font(.headline)
                Spacer()
                if let lastUpdated {
                    Text(lastUpdated, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if processes.isEmpty {
                Text("No process sample available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("By CPU")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(topProcessesByCPU, id: \.pid) { process in
                            processRow(process, metricText: String(format: "%.1f%%", process.cpuPercent), color: loadColor(process.cpuPercent))
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("By Memory")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(topProcessesByMemory, id: \.pid) { process in
                            processRow(process, metricText: String(format: "%.1f%%", process.memoryPercent), color: loadColor(process.memoryPercent))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func processRow(_ process: FfiProcess, metricText: String, color: Color) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(process.command.isEmpty ? process.args : process.command)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(process.user)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(metricText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.vertical, 3)
    }

    private var topProcessesByCPU: [FfiProcess] {
        Array(
            processes
                .sorted { $0.cpuPercent > $1.cpuPercent }
                .prefix(5)
        )
    }

    private var topProcessesByMemory: [FfiProcess] {
        Array(
            processes
                .sorted { $0.memoryPercent > $1.memoryPercent }
                .prefix(5)
        )
    }

    private var memoryPercent: Double {
        guard let stats, stats.memoryTotal > 0 else { return 0 }
        return Double(stats.memoryUsed) / Double(stats.memoryTotal) * 100
    }

    private var memoryPercentText: String {
        stats == nil ? "-" : percent(memoryPercent)
    }

    private var memoryDetail: String {
        guard let stats else { return "Waiting for sample" }
        return "\(bytes(stats.memoryUsed)) / \(bytes(stats.memoryTotal))"
    }

    private var swapPercent: Double {
        guard let stats, stats.swapTotal > 0 else { return 0 }
        return Double(stats.swapUsed) / Double(stats.swapTotal) * 100
    }

    private var swapUsed: UInt64 {
        stats?.swapUsed ?? 0
    }

    private var swapPercentText: String {
        guard let stats, stats.swapTotal > 0 else { return "0%" }
        return percent(swapPercent)
    }

    private var swapDetail: String {
        guard let stats, stats.swapTotal > 0 else { return "No swap" }
        return "\(bytes(stats.swapUsed)) / \(bytes(stats.swapTotal))"
    }

    private var primaryDisk: FfiDiskMount? {
        guard let stats else { return nil }
        return stats.disks.first { $0.mount == "/" } ?? stats.disks.max { lhs, rhs in
            usedPercent(lhs) < usedPercent(rhs)
        }
    }

    private var diskPercent: Double {
        primaryDisk.map(usedPercent) ?? 0
    }

    private var diskPercentText: String {
        primaryDisk == nil ? "-" : percent(diskPercent)
    }

    private var diskDetail: String {
        guard let disk = primaryDisk else { return "No disk sample" }
        return "\(disk.mount) \(bytes(disk.used)) / \(bytes(disk.total))"
    }

    private var uptimeText: String {
        guard let seconds = stats?.uptimeSeconds else { return "-" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        return "\(hours)h"
    }

    private var ufwColor: Color {
        switch ufwSummary.level {
        case .loading:
            return .secondary
        case .unavailable:
            return .secondary
        case .inactive:
            return .red
        case .protected:
            return .green
        case .open:
            return .orange
        case .unknown:
            return .orange
        }
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil

        async let statsTask = loadStats()
        async let processTask = loadProcesses()
        async let ufwTask = loadUFW()

        var failures: [String] = []

        do {
            stats = try await statsTask
        } catch {
            failures.append(describe(error))
        }

        do {
            processes = try await processTask
        } catch {
            failures.append(describe(error))
        }

        do {
            ufwSummary = try await ufwTask
        } catch {
            ufwSummary = MobileUFWProtectionSummary(
                level: .unknown,
                statusText: "Unable to read UFW status",
                extraOpenRules: [],
                error: describe(error)
            )
        }

        lastUpdated = Date()
        errorMessage = failures.first
        isLoading = false
    }

    private func loadStats() async throws -> FfiSystemStats {
        try await MobileMonitorBridge.shared.getSystemStats(connectionId: connectionId)
    }

    private func loadProcesses() async throws -> [FfiProcess] {
        try await MobileMonitorBridge.shared.getProcesses(connectionId: connectionId)
    }

    private func loadUFW() async throws -> MobileUFWProtectionSummary {
        let script = """
        if command -v ufw >/dev/null 2>&1; then
          sudo -n ufw status numbered 2>&1
        else
          echo __MIDNIGHT_SSH_UFW_UNAVAILABLE__
        fi
        """
        let output = try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )
        return MobileUFWProtectionSummary(output: output, sshPort: sshPort)
    }

    private func describe(_ error: Error) -> String {
        if let monitorError = error as? MonitorError {
            switch monitorError {
            case .NotConnected:
                return "Not connected to this host."
            case .ParseError(let detail):
                return detail
            case .Unsupported(let os):
                return "Unsupported host OS: \(os)."
            case .Other(let detail):
                return detail
            }
        }
        return error.localizedDescription
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.0f%%", value)
    }

    private func number(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.2f", value)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private func usedPercent(_ disk: FfiDiskMount) -> Double {
        guard disk.total > 0 else { return 0 }
        return Double(disk.used) / Double(disk.total) * 100
    }

    private func loadColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 75 { return .orange }
        return .green
    }
}

private enum MobileUFWProtectionLevel: Equatable {
    case loading
    case unavailable
    case inactive
    case protected
    case open
    case unknown
}

private struct MobileUFWProtectionSummary: Equatable {
    private struct OpenRuleExposure {
        let target: String
        let source: String
    }

    let level: MobileUFWProtectionLevel
    let statusText: String
    let extraOpenRules: [String]
    let error: String?

    static let loading = MobileUFWProtectionSummary(
        level: .loading,
        statusText: "Loading UFW status",
        extraOpenRules: [],
        error: nil
    )

    init(level: MobileUFWProtectionLevel, statusText: String, extraOpenRules: [String], error: String?) {
        self.level = level
        self.statusText = statusText
        self.extraOpenRules = extraOpenRules
        self.error = error
    }

    init(output: String, sshPort: UInt16?) {
        let statusText = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Unknown"

        if output.contains("__MIDNIGHT_SSH_UFW_UNAVAILABLE__") {
            self.init(
                level: .unavailable,
                statusText: "UFW not installed",
                extraOpenRules: [],
                error: nil
            )
            return
        }

        let lower = statusText.lowercased()
        if lower.contains("inactive") {
            self.init(
                level: .inactive,
                statusText: statusText,
                extraOpenRules: [],
                error: nil
            )
            return
        }

        if lower.contains("active") {
            let extraRules = Self.collectExtraOpenRules(from: output, sshPort: sshPort)
            self.init(
                level: extraRules.isEmpty ? .protected : .open,
                statusText: statusText,
                extraOpenRules: extraRules,
                error: nil
            )
            return
        }

        let permissionError = lower.contains("permission")
            || lower.contains("need to be root")
            || lower.contains("must be root")
            || lower.contains("password")
        self.init(
            level: .unknown,
            statusText: statusText,
            extraOpenRules: [],
            error: permissionError ? statusText : nil
        )
    }

    var badgeText: String {
        switch level {
        case .loading:
            return "..."
        case .unavailable:
            return "n/a"
        case .inactive:
            return "off"
        case .protected:
            return "on"
        case .open:
            return "open"
        case .unknown:
            return "?"
        }
    }

    var detail: String {
        switch level {
        case .open where !extraOpenRules.isEmpty:
            return "Extra open: \(extraOpenRules.prefix(2).joined(separator: ", "))"
        case .unknown:
            return error ?? statusText
        default:
            return statusText
        }
    }

    private static func collectExtraOpenRules(from output: String, sshPort: UInt16?) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { extractOpenRuleExposure(from: String($0)) }
            .filter { isPublicSource($0.source) && !isAllowedOpenRule($0.target, sshPort: sshPort) }
            .map(\.target)
    }

    private static func extractOpenRuleExposure(from line: String) -> OpenRuleExposure? {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("Status:"),
              !trimmed.hasPrefix("To "),
              !trimmed.hasPrefix("--")
        else { return nil }

        if trimmed.hasPrefix("["),
           let end = trimmed.firstIndex(of: "]") {
            trimmed = String(trimmed[trimmed.index(after: end)...])
                .trimmingCharacters(in: .whitespaces)
        }

        let pattern = #"^(.+?)\s{2,}(ALLOW(?:\s+(?:IN|OUT))?|LIMIT(?:\s+(?:IN|OUT))?)\s{2,}(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges >= 4,
              let targetRange = Range(match.range(at: 1), in: trimmed),
              let sourceRange = Range(match.range(at: 3), in: trimmed)
        else { return nil }

        let target = trimmed[targetRange]
            .trimmingCharacters(in: .whitespaces)
        let source = stripRuleComment(String(trimmed[sourceRange]))
        guard !target.isEmpty, !source.isEmpty else { return nil }
        return OpenRuleExposure(target: target, source: source)
    }

    private static func isPublicSource(_ source: String) -> Bool {
        let normalized = stripRuleComment(source)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()

        return [
            "any",
            "anyone",
            "anyone (v6)",
            "anywhere",
            "anywhere (v6)",
            "0.0.0.0/0",
            "::/0",
            "::/0 (v6)",
        ].contains(normalized)
    }

    private static func stripRuleComment(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commentRange = trimmed.range(of: " # ") else {
            return trimmed
        }
        return String(trimmed[..<commentRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAllowedOpenRule(_ rule: String, sshPort: UInt16?) -> Bool {
        let normalized = rule
            .replacingOccurrences(of: "(v6)", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()

        let allowedServices: Set<String> = [
            "http",
            "https",
            "ssh",
            "openssh",
            "www",
            "www full",
            "www secure",
            "apache",
            "apache full",
            "apache secure",
            "nginx http",
            "nginx https",
            "nginx full",
        ]
        if allowedServices.contains(normalized) {
            return true
        }

        guard let portSpec = normalized.split(whereSeparator: \.isWhitespace).first else {
            return false
        }
        let portPart = portSpec.split(separator: "/").first.map(String.init) ?? String(portSpec)
        let ports = portPart.split(separator: ",").map(String.init)
        guard !ports.isEmpty else { return false }

        var allowedPorts: Set<String> = ["22", "80", "443"]
        allowedPorts.insert(String(sshPort ?? 22))
        return ports.allSatisfy { allowedPorts.contains($0) }
    }
}

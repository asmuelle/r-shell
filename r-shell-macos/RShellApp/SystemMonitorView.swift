import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog
import RShellMacOS

fileprivate enum MonitorDrillDown: Identifiable {
    case cpu
    case memory
    case disk(FfiDiskMount)
    case systemdService(String)
    case ufw

    var id: String {
        switch self {
        case .cpu:
            return "cpu"
        case .memory:
            return "memory"
        case .disk(let disk):
            return "disk:\(disk.mount):\(disk.source)"
        case .systemdService(let unit):
            return "systemd:\(unit)"
        case .ufw:
            return "ufw"
        }
    }

    var title: String {
        switch self {
        case .cpu:
            return "CPU Analysis"
        case .memory:
            return "Memory Analysis"
        case .disk(let disk):
            return "Recent Large Files: \(disk.mount)"
        case .systemdService(let unit):
            return unit
        case .ufw:
            return "UFW Details"
        }
    }

    var subtitle: String {
        switch self {
        case .cpu:
            return "CPU-heavy processes, thread hot spots, and current load."
        case .memory:
            return "Memory-heavy processes, pressure signals, and allocation summary."
        case .disk(let disk):
            return "\(disk.source) - files changed in the last 14 days, sorted by size."
        case .systemdService:
            return "Unit identity, environment, service files, recent logs, and actions."
        case .ufw:
            return "Firewall status, numbered rules, defaults, recent blocks, and raw rules."
        }
    }

    var icon: String {
        switch self {
        case .cpu:
            return "cpu"
        case .memory:
            return "memorychip"
        case .disk:
            return "internaldrive"
        case .systemdService:
            return "switch.2"
        case .ufw:
            return "shield"
        }
    }
}

fileprivate enum MonitorDrillDown: Identifiable {
    case cpu
    case memory
    case disk(FfiDiskMount)
    case systemdService(String)
    case ufw

    var id: String {
        switch self {
        case .cpu:
            return "cpu"
        case .memory:
            return "memory"
        case .disk(let disk):
            return "disk:\(disk.mount):\(disk.source)"
        case .systemdService(let unit):
            return "systemd:\(unit)"
        case .ufw:
            return "ufw"
        }
    }

    var title: String {
        switch self {
        case .cpu:
            return "CPU Analysis"
        case .memory:
            return "Memory Analysis"
        case .disk(let disk):
            return "Recent Large Files: \(disk.mount)"
        case .systemdService(let unit):
            return unit
        case .ufw:
            return "UFW Details"
        }
    }

    var subtitle: String {
        switch self {
        case .cpu:
            return "CPU-heavy processes, thread hot spots, and current load."
        case .memory:
            return "Memory-heavy processes, pressure signals, and allocation summary."
        case .disk(let disk):
            return "\(disk.source) - files changed in the last 14 days, sorted by size."
        case .systemdService:
            return "Unit identity, environment, service files, recent logs, and actions."
        case .ufw:
            return "Firewall status, numbered rules, defaults, recent blocks, and raw rules."
        }
    }

    var icon: String {
        switch self {
        case .cpu:
            return "cpu"
        case .memory:
            return "memorychip"
        case .disk:
            return "internaldrive"
        case .systemdService:
            return "switch.2"
        case .ufw:
            return "shield"
        }
    }
}

/// Polls host stats through `BridgeManager` every few seconds for the active
/// connection and renders CPU / memory / per-mount disk / uptime / load.
///
/// **Multi-OS**: the Rust side runs `uname -s` once per connection
/// (cached) and routes to the matching parser. Linux (`/proc`) and
/// macOS (`top`/`vm_stat`/`sysctl`/`df -k -P`) are supported; BSD /
/// Solaris hosts surface as `MonitorError.Unsupported` and we render
/// a friendly placeholder instead of error spam.
///
/// The polling Task is bound to the view's lifetime via `.task` —
/// switching tabs or disconnecting tears it down automatically.
struct SystemMonitorView: View {
    let connectionId: String?
    let connectionLabel: String
    var profileId: String? = nil
    var sshPort: UInt16? = nil
    var profile: ConnectionProfile? = nil
    var connectionStatus: TerminalConnectionStatus? = nil
    var isActive: Bool = true

    @State private var stats: FfiSystemStats?
    @State private var error: String?
    @State private var ufwSummary = UFWProtectionSummary.loading
    /// Set when the host's OS isn't supported. Renders a stable
    /// placeholder so we don't spam the user with parse errors on
    /// every poll. Reset on connection change.
    @State private var unsupportedOs: String?
    /// Sliding window of recent samples for the CPU / memory trend
    /// charts. Capped at `maxHistory` — older samples are dropped at
    /// each append. Reset on `connectionId` change so a switch between
    /// hosts doesn't render misleading lines that span both.
    @State private var history: [StatSample] = []
    @State private var lastConnectionId: String?
    @State private var drillDown: MonitorDrillDown?

    private let logger = Logger(subsystem: "com.r-shell", category: "monitor")
    private static let pollInterval: UInt64 = 3_000_000_000  // 3 s
    private static let ufwPollInterval: UInt64 = 30_000_000_000  // 30 s
    /// 60 × 3s = 3 minutes of trailing history per chart.
    private static let maxHistory = 60

    /// One CPU/memory snapshot for the trend charts.
    fileprivate struct StatSample: Identifiable {
        let id = UUID()
        let timestamp: Date
        let cpuPercent: Double
        /// Memory utilisation 0..100 — derived from used / total at
        /// sample time so the chart's Y axis aligns with the linear
        /// progress bar above it.
        let memoryPercent: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: pollTaskKey) {
            guard isActive else { return }
            await pollLoop()
        }
        .task(id: ufwPollTaskKey) {
            guard isActive, let connectionId else {
                ufwSummary = connectionId == nil
                    ? UFWProtectionSummary(
                        level: .unavailable,
                        statusText: "No connection",
                        extraOpenRules: [],
                        error: nil
                    )
                    : .loading
                return
            }
            await ufwPollLoop(connectionId: connectionId)
        }
        .sheet(item: $drillDown) { item in
            MonitorDrillDownSheet(
                connectionId: connectionId,
                drillDown: item,
                sshPort: sshPort
            )
        }
    }

    private var pollTaskKey: String {
        "\(connectionId ?? "none"):\(isActive)"
    }

    private var ufwPollTaskKey: String {
        "\(connectionId ?? "none"):\(sshPort.map { String($0) } ?? "default"):\(isActive)"
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(.secondary)
            Text(connectionLabel)
                .font(.headline)
            if connectionId != nil {
                ufwStatusBadge
            }
            Spacer()
            if stats != nil {
                Text("Updated \(Date().formatted(.dateTime.hour().minute().second()))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var ufwStatusBadge: some View {
        let color = ufwProtectionColor(ufwSummary)
        return Button {
            drillDown = .ufw
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text("UFW \(ufwSummary.badgeText)")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .help(ufwSummary.helpText)
    }

    private func ufwProtectionColor(_ summary: UFWProtectionSummary) -> Color {
        switch summary.level {
        case .protected:
            return .green
        case .inactive, .open:
            return .orange
        case .unknown:
            return .yellow
        case .loading, .unavailable:
            return .secondary
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if connectionId == nil {
            placeholder(
                icon: "network.slash",
                message: "Open a terminal session to see live host stats."
            )
        } else if let unsupportedOs {
            placeholder(
                icon: "questionmark.circle",
                message: "Host OS \"\(unsupportedOs)\" isn't supported yet — only Linux and macOS hosts are recognised."
            )
        } else if let error {
            placeholder(icon: "exclamationmark.triangle", message: error)
        } else if let stats {
            statsBody(stats)
        } else {
            ProgressView("Loading host stats…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stats body

    private func statsBody(_ stats: FfiSystemStats) -> some View {
        let memoryPercent = stats.memoryTotal > 0
            ? Double(stats.memoryUsed) / Double(stats.memoryTotal) * 100
            : 0

        return GeometryReader { proxy in
            ScrollView {
                let contentHeight = max(0, proxy.size.height - 32)

                VStack(alignment: .leading, spacing: 16) {
                    if let profile {
                        ConnectionConfidenceView(
                            profile: profile,
                            status: connectionStatus
                        )
                    }

                    metricBlock(
                        title: "CPU",
                        icon: "cpu",
                        progress: stats.cpuPercent / 100,
                        rightLabel: String(format: "%.1f%%", stats.cpuPercent),
                        series: \.cpuPercent
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { drillDown = .cpu }
                    .help("Analyze CPU-intensive processes")

                    metricBlock(
                        title: "Memory",
                        icon: "memorychip",
                        progress: memoryPercent / 100,
                        rightLabel: "\(formatBytes(stats.memoryUsed)) / \(formatBytes(stats.memoryTotal))",
                        series: \.memoryPercent
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { drillDown = .memory }
                    .help("Analyze memory-intensive processes")

                    if stats.swapTotal > 0 {
                        metricRow(
                            title: "Swap",
                            icon: "arrow.up.arrow.down.square",
                            progress: Double(stats.swapUsed) / Double(stats.swapTotal),
                            rightLabel: "\(formatBytes(stats.swapUsed)) / \(formatBytes(stats.swapTotal))"
                        )
                    }

                    disksSection(stats.disks)

                    Divider()

                    summaryRow(
                        icon: "clock",
                        label: "Uptime",
                        value: formatUptime(stats.uptimeSeconds)
                    )

                    summaryRow(
                        icon: "speedometer",
                        label: "Load (1 min)",
                        value: String(format: "%.2f", stats.loadAverage1m)
                    )

                    MonitoredSystemdServicesPane(
                        connectionId: connectionId,
                        profileId: profileId,
                        isActive: isActive,
                        onSelectService: { unit in
                            drillDown = .systemdService(unit)
                        }
                    )

                    ActivityTimelineView(
                        profileId: profileId,
                        connectionId: connectionId,
                        maxEvents: 6
                    )

                    Spacer(minLength: 16)

                    if let connectionId {
                        ConnectionWorldMapView(connectionId: connectionId)
                    }
                }
                .frame(minHeight: contentHeight, alignment: .top)
                .padding(16)
            }
        }
    }

    private func metricRow(
        title: String,
        icon: String,
        progress: Double,
        rightLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(rightLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: max(0, min(1, progress)))
                .progressViewStyle(.linear)
                .tint(progressTint(progress))
        }
    }

    /// Same as `metricRow` plus a sparkline of recent samples below.
    /// `series` is a key path on `StatSample` so the same block works
    /// for CPU and memory without duplicating the chart wiring.
    private func metricBlock(
        title: String,
        icon: String,
        progress: Double,
        rightLabel: String,
        series: KeyPath<StatSample, Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            metricRow(
                title: title,
                icon: icon,
                progress: progress,
                rightLabel: rightLabel
            )

            // Need at least two points to draw a line; until then, leave
            // a small gap so the layout doesn't jump on the first sample.
            if history.count >= 2 {
                Chart(history) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value(title, sample[keyPath: series])
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(progressTint(progress))

                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value(title, sample[keyPath: series])
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(progressTint(progress).opacity(0.15))
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 40)
            } else {
                Color.clear.frame(height: 40)
            }
        }
    }

    /// Per-mount disk-usage section. Renders one `metricRow` per
    /// volume; collapses to a single placeholder when nothing came
    /// back (e.g. a host where `df` was filtered out by SELinux or
    /// chroot). The mount path is used as the row's identity since
    /// it's unique per host.
    @ViewBuilder
    private func disksSection(_ disks: [FfiDiskMount]) -> some View {
        if disks.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("No disk mounts reported")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Disks")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                ForEach(disks, id: \.mount) { disk in
                    diskRow(disk)
                }
            }
        }
    }

    private func diskRow(_ disk: FfiDiskMount) -> some View {
        let progress = disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(disk.mount)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(formatBytes(disk.used)) / \(formatBytes(disk.total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: max(0, min(1, progress)))
                .progressViewStyle(.linear)
                .tint(progressTint(progress))
            HStack(spacing: 4) {
                Text(disk.source)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if disk.fsType != "—" && !disk.fsType.isEmpty {
                    Text("·")
                    Text(disk.fsType)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.leading, 22)
        .contentShape(Rectangle())
        .onTapGesture { drillDown = .disk(disk) }
        .help("Show recently changed large files on \(disk.mount)")
    }

    private func summaryRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func progressTint(_ value: Double) -> Color {
        switch value {
        case ..<0.6:  return .green
        case ..<0.85: return .orange
        default:      return .red
        }
    }

    // MARK: - Polling

    private func pollLoop() async {
        // Drop the previous connection's history and any sticky error /
        // unsupported flag only when this view is retargeted to a different
        // connection. When it merely becomes inactive and active again, keep
        // its chart history as part of the tab's preserved workspace state.
        if lastConnectionId != connectionId {
            history.removeAll()
            unsupportedOs = nil
            error = nil
            lastConnectionId = connectionId
        }

        guard let connectionId else { return }
        while !Task.isCancelled {
            await fetchOnce(connectionId: connectionId)
            // If we know the host is unsupported, stop polling — the
            // result won't change without a reconnect, and the timer
            // would just churn on the same uname/parser.
            if unsupportedOs != nil { return }
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    private func ufwPollLoop(connectionId: String) async {
        await fetchUFWStatus(connectionId: connectionId)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.ufwPollInterval)
            await fetchUFWStatus(connectionId: connectionId)
        }
    }

    private func fetchUFWStatus(connectionId: String) async {
        let script = """
        if command -v ufw >/dev/null 2>&1; then
          sudo -n ufw status numbered 2>&1
        else
          echo \(ufwUnavailableMarker)
        fi
        """

        do {
            let result = try await RemoteCommandRunner.runShell(
                connectionId: connectionId,
                script: script
            )
            if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !result.succeeded {
                ufwSummary = UFWProtectionSummary(
                    level: .unknown,
                    statusText: "Unable to read UFW status",
                    extraOpenRules: [],
                    error: "Remote command failed with exit code \(result.exitCode)."
                )
            } else {
                ufwSummary = summarizeUFWStatusOutput(result.output, sshPort: sshPort)
            }
        } catch {
            ufwSummary = UFWProtectionSummary(
                level: .unknown,
                statusText: "Unable to read UFW status",
                extraOpenRules: [],
                error: friendlyUFWError(error.localizedDescription)
            )
        }
    }

    private func friendlyUFWError(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("a password is required")
            || (lower.contains("sudo") && lower.contains("password")) {
            return "UFW inspection uses sudo -n. Configure passwordless sudo for ufw status, or run the command manually in the terminal."
        }
        return message
    }

    /// Append a sample, capping the buffer to `maxHistory`. Memory %
    /// is derived once here so the chart's series lookup stays cheap.
    private func recordSample(_ s: FfiSystemStats) {
        let memoryPct = s.memoryTotal > 0
            ? Double(s.memoryUsed) / Double(s.memoryTotal) * 100
            : 0
        history.append(StatSample(
            timestamp: Date(),
            cpuPercent: s.cpuPercent,
            memoryPercent: memoryPct
        ))
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
    }

    private func fetchOnce(connectionId: String) async {
        do {
            let s = try await BridgeManager.shared.getSystemStats(connectionId: connectionId)
            stats = s
            error = nil
            unsupportedOs = nil
            recordSample(s)
        } catch let err as MonitorError {
            switch err {
            case .Unsupported(let os):
                // The Rust side detected the OS via `uname -s` and
                // doesn't have parsers for it. Surface the kernel
                // name so the user knows whether to file a request.
                unsupportedOs = os
                error = nil
            case .ParseError(let detail):
                // Output didn't match the expected shape — usually
                // a transient command timeout or a sysctl that's
                // missing on a stripped-down host. Show the detail
                // and let the next poll retry.
                error = "Couldn't parse host stats: \(detail)"
            case .NotConnected:
                error = "Not connected to this host."
            case .Other(let detail):
                error = detail
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func formatUptime(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Monitor drill-down sheet

private struct MonitorDrillDownSheet: View {
    let connectionId: String?
    let drillDown: MonitorDrillDown
    let sshPort: UInt16?

    @Environment(\.dismiss) private var dismiss
    @State private var rawOutput = ""
    @State private var snapshot: MonitorDiagnosticSnapshot?
    @State private var error: String?
    @State private var notice: String?
    @State private var isLoading = false
    @State private var mode = DrillDownMode.overview
    @State private var selectedProcessId: Int?
    @State private var selectedThreadId: String?
    @State private var selectedFilePath: String?
    @State private var selectedSystemdFileId: String?
    @State private var selectedUFWRuleId: Int?
    @State private var selectedUFWSource: String?
    @State private var focusedTitle: String?
    @State private var focusedOutput = ""
    @State private var focusedLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, notice == nil ? 10 : 4)
            }
            Picker("", selection: $mode) {
                ForEach(DrillDownMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            diagnosticContent
        }
        .frame(minWidth: 860, idealWidth: 980, minHeight: 620, idealHeight: 720)
        .task(id: drillDown.id) {
            await refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: drillDown.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(drillDown.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(drillDown.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            systemdActions
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .disabled(isLoading)
            .help("Refresh")

            Button {
                RemoteCommandRunner.copy(mode == .raw ? rawOutput : focusedOutput)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .disabled((mode == .raw ? rawOutput : focusedOutput).isEmpty)
            .help("Copy")

            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var diagnosticContent: some View {
        if mode == .raw {
            rawPane(rawOutput)
        } else if let snapshot {
            switch snapshot {
            case .cpu(let diagnostic):
                cpuContent(diagnostic)
            case .memory(let diagnostic):
                memoryContent(diagnostic)
            case .disk(let diagnostic):
                diskContent(diagnostic)
            case .systemd(let diagnostic):
                systemdContent(diagnostic)
            case .ufw(let diagnostic):
                ufwContent(diagnostic)
            }
        } else if isLoading {
            ProgressView("Loading diagnostics...")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            placeholderPane("No diagnostic data.")
        }
    }

    @ViewBuilder
    private var systemdActions: some View {
        if case .systemdService(let unit) = drillDown {
            HStack(spacing: 6) {
                Button {
                    Task { await runSystemdAction("start", unit: unit) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(isLoading)
                .help("Start service")

                Button {
                    Task { await runSystemdAction("stop", unit: unit) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(isLoading)
                .help("Stop service")

                Button {
                    Task { await runSystemdAction("restart", unit: unit) }
                } label: {
                    Label("Restart", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isLoading)
                .help("Restart service")

                Button {
                    Task { await runSystemdAction("reload", unit: unit) }
                } label: {
                    Label("Reload", systemImage: "arrow.down.doc")
                }
                .disabled(isLoading)
                .help("Reload service")
            }
        }
    }

    @MainActor
    private func refresh() async {
        guard let connectionId else {
            rawOutput = ""
            snapshot = nil
            error = "No SSH connection selected."
            return
        }

        isLoading = true
        error = nil
        notice = nil
        defer { isLoading = false }

        do {
            let result = try await RemoteCommandRunner.runShell(
                connectionId: connectionId,
                script: diagnosticScript()
            )
            rawOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot = MonitorDiagnosticParser.parse(rawOutput, kind: drillDown)
            applyDefaultSelections()
            ActivityLogStore.shared.record(
                title: "Deep dive opened",
                detail: drillDown.title,
                connectionId: connectionId,
                icon: drillDown.icon,
                severity: result.succeeded ? .info : .warning
            )
            if result.succeeded {
                error = nil
            } else {
                error = "Diagnostics exited with code \(result.exitCode)."
            }
        } catch {
            self.error = error.localizedDescription
            rawOutput = ""
            snapshot = nil
        }
    }

    @MainActor
    private func runSystemdAction(_ verb: String, unit: String) async {
        guard let connectionId else {
            error = "No SSH connection selected."
            return
        }

        isLoading = true
        error = nil
        notice = nil
        defer { isLoading = false }

        let quotedUnit = RemoteCommandRunner.shellQuote(unit)
        let script = """
        command -v systemctl >/dev/null 2>&1 || { echo "systemctl is not available on this host."; exit 127; }
        systemctl \(verb) \(quotedUnit) 2>&1
        status=$?
        if [ "$status" -ne 0 ]; then
          sudo -n systemctl \(verb) \(quotedUnit) 2>&1
          status=$?
        fi
        exit "$status"
        """

        do {
            let result = try await RemoteCommandRunner.runShell(connectionId: connectionId, script: script)
            rawOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.succeeded {
                let message = "\(verb.capitalized) completed for \(unit)."
                ActivityLogStore.shared.record(
                    title: "Service \(verb)",
                    detail: unit,
                    connectionId: connectionId,
                    icon: "switch.2",
                    severity: .success
                )
                await refresh()
                notice = message
            } else {
                ActivityLogStore.shared.record(
                    title: "Service \(verb) failed",
                    detail: unit,
                    connectionId: connectionId,
                    icon: "exclamationmark.triangle.fill",
                    severity: .critical
                )
                error = "\(verb.capitalized) exited with code \(result.exitCode)."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func runFocusedInspection(title: String, script: String) async {
        guard let connectionId else {
            error = "No SSH connection selected."
            return
        }

        focusedTitle = title
        focusedLoading = true
        focusedOutput = ""
        defer { focusedLoading = false }

        do {
            let result = try await RemoteCommandRunner.runShell(connectionId: connectionId, script: script)
            focusedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.succeeded {
                error = "Inspection exited with code \(result.exitCode)."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applyDefaultSelections() {
        guard let snapshot else { return }
        switch snapshot {
        case .cpu(let diagnostic):
            selectedProcessId = diagnostic.processes.first?.pid
            selectedThreadId = diagnostic.threads.first?.id
        case .memory(let diagnostic):
            selectedProcessId = diagnostic.processes.first?.pid
        case .disk(let diagnostic):
            selectedFilePath = diagnostic.files.first?.path
        case .systemd(let diagnostic):
            selectedSystemdFileId = diagnostic.files.first?.id
        case .ufw(let diagnostic):
            selectedUFWRuleId = diagnostic.rules.first?.id
            selectedUFWSource = diagnostic.blockedSources.first
        }
        focusedTitle = nil
        focusedOutput = ""
    }

    // MARK: - Typed panes

    @ViewBuilder
    private func cpuContent(_ diagnostic: CPUDiagnostic) -> some View {
        switch mode {
        case .overview:
            overviewPane([
                ("Load", diagnostic.load.isEmpty ? "Unavailable" : diagnostic.load),
                ("CPU Cores", diagnostic.cores.isEmpty ? "Unknown" : diagnostic.cores),
                ("Processes", "\(diagnostic.processes.count)"),
                ("Threads", "\(diagnostic.threads.count)"),
            ], warnings: diagnostic.warnings)
        case .hotspots:
            processHotspotPane(
                processes: diagnostic.processes,
                threads: diagnostic.threads
            )
        case .details:
            selectedProcessDetail(diagnostic.processes)
        case .raw:
            rawPane(rawOutput)
        }
    }

    @ViewBuilder
    private func memoryContent(_ diagnostic: MemoryDiagnostic) -> some View {
        switch mode {
        case .overview:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    overviewCards([
                        ("Processes", "\(diagnostic.processes.count)"),
                        ("Memory Events", "\(diagnostic.events.count)"),
                        ("Largest RSS", diagnostic.processes.first.map { formatKilobytes($0.rssKB) } ?? "Unknown"),
                    ])
                    sectionBox("Memory Summary") {
                        rawText(diagnostic.summary.joined(separator: "\n"))
                    }
                    if !diagnostic.warnings.isEmpty {
                        warningList(diagnostic.warnings)
                    }
                }
                .padding(16)
            }
        case .hotspots:
            processHotspotPane(
                processes: diagnostic.processes,
                threads: []
            )
        case .details:
            VStack(alignment: .leading, spacing: 12) {
                selectedProcessDetail(diagnostic.processes)
                if !diagnostic.events.isEmpty {
                    sectionBox("Memory Pressure Events") {
                        rawText(diagnostic.events.joined(separator: "\n"))
                    }
                    .frame(height: 180)
                }
            }
        case .raw:
            rawPane(rawOutput)
        }
    }

    @ViewBuilder
    private func diskContent(_ diagnostic: DiskDiagnostic) -> some View {
        switch mode {
        case .overview:
            overviewPane([
                ("Mount", diagnostic.mount.isEmpty ? "Unknown" : diagnostic.mount),
                ("Usage", diagnostic.usage.isEmpty ? "Unavailable" : diagnostic.usage),
                ("Recent Large Files", "\(diagnostic.files.count)"),
                ("Largest File", diagnostic.files.first.map { formatBytes($0.size) } ?? "None"),
            ], warnings: diagnostic.warnings)
        case .hotspots:
            diskFilePane(diagnostic)
        case .details:
            selectedDiskFileDetail(diagnostic.files)
                .padding(16)
        case .raw:
            rawPane(rawOutput)
        }
    }

    @ViewBuilder
    private func systemdContent(_ diagnostic: SystemdDiagnostic) -> some View {
        switch mode {
        case .overview:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    overviewCards([
                        ("Active", diagnostic.value(for: "ActiveState") ?? "Unknown"),
                        ("Substate", diagnostic.value(for: "SubState") ?? "Unknown"),
                        ("User", diagnostic.value(for: "User") ?? "Default"),
                        ("Main PID", diagnostic.value(for: "MainPID") ?? "Unknown"),
                    ])
                    serviceSpecificPane(diagnostic)
                    keyValuePane(diagnostic.properties)
                }
                .padding(16)
            }
        case .hotspots:
            systemdFilesPane(diagnostic)
        case .details:
            systemdJournalPane(diagnostic)
        case .raw:
            rawPane(rawOutput)
        }
    }

    @ViewBuilder
    private func ufwContent(_ diagnostic: UFWDiagnostic) -> some View {
        switch mode {
        case .overview:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    overviewCards([
                        ("Rules", "\(diagnostic.rules.count)"),
                        ("Blocked Sources", "\(diagnostic.blockedSources.count)"),
                        ("Status Lines", "\(diagnostic.statusLines.count)"),
                        ("SSH Port", sshPort.map { String($0) } ?? "22"),
                    ])
                    sectionBox("Status") {
                        rawText(diagnostic.statusLines.joined(separator: "\n"))
                    }
                }
                .padding(16)
            }
        case .hotspots:
            ufwRulesPane(diagnostic)
        case .details:
            ufwBlockedSourcesPane(diagnostic)
        case .raw:
            rawPane(rawOutput)
        }
    }

    private func processHotspotPane(
        processes: [ProcessDiagnosticRow],
        threads: [ThreadDiagnosticRow]
    ) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                processTable(processes)
                    .frame(minHeight: 320)
                if !threads.isEmpty {
                    Text("Thread Hotspots")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    threadTable(threads)
                        .frame(height: 150)
                }
            }
            .padding(12)
            .frame(minWidth: 520)

            selectedProcessDetail(processes)
                .padding(12)
                .frame(minWidth: 320)
        }
    }

    private func processTable(_ processes: [ProcessDiagnosticRow]) -> some View {
        Table(processes, selection: Binding(
            get: { selectedProcessId },
            set: {
                selectedProcessId = $0
                focusedTitle = nil
                focusedOutput = ""
            }
        )) {
            TableColumn("PID") { row in
                Text("\(row.pid)")
                    .font(.caption.monospacedDigit())
            }
            .width(min: 55, ideal: 65)

            TableColumn("User") { row in
                Text(row.user)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 110)

            TableColumn("%CPU") { row in
                Text(String(format: "%.1f", row.cpuPercent))
                    .font(.caption.monospacedDigit())
            }
            .width(min: 55, ideal: 65)

            TableColumn("%MEM") { row in
                Text(String(format: "%.1f", row.memoryPercent))
                    .font(.caption.monospacedDigit())
            }
            .width(min: 55, ideal: 65)

            TableColumn("RSS") { row in
                Text(row.rssKB == 0 ? "-" : formatKilobytes(row.rssKB))
                    .font(.caption.monospacedDigit())
            }
            .width(min: 70, ideal: 90)

            TableColumn("Command") { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.command)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(row.arguments)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func threadTable(_ threads: [ThreadDiagnosticRow]) -> some View {
        Table(threads, selection: Binding(
            get: { selectedThreadId },
            set: { selectedThreadId = $0 }
        )) {
            TableColumn("PID") { row in
                Text("\(row.pid)")
                    .font(.caption.monospacedDigit())
            }
            .width(min: 55, ideal: 65)
            TableColumn("TID") { row in
                Text(row.threadId)
                    .font(.caption.monospacedDigit())
            }
            .width(min: 70, ideal: 90)
            TableColumn("%CPU") { row in
                Text(String(format: "%.1f", row.cpuPercent))
                    .font(.caption.monospacedDigit())
            }
            .width(min: 60, ideal: 70)
            TableColumn("Command") { row in
                Text(row.command)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
    }

    private func selectedProcessDetail(_ processes: [ProcessDiagnosticRow]) -> some View {
        let process = selectedProcessId.flatMap { id in processes.first { $0.pid == id } }
        return VStack(alignment: .leading, spacing: 10) {
            if let process {
                HStack {
                    Text(process.command)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        Task {
                            await runFocusedInspection(
                                title: "Process \(process.pid)",
                                script: Self.processInspectionScript(pid: process.pid)
                            )
                        }
                    } label: {
                        Label("Inspect", systemImage: "magnifyingglass")
                    }
                    .disabled(focusedLoading)
                }
                keyValuePane([
                    ("PID", "\(process.pid)"),
                    ("Parent PID", "\(process.ppid)"),
                    ("User", process.user),
                    ("State", process.state),
                    ("%CPU", String(format: "%.1f", process.cpuPercent)),
                    ("%MEM", String(format: "%.1f", process.memoryPercent)),
                    ("RSS", formatKilobytes(process.rssKB)),
                    ("VSZ", formatKilobytes(process.vszKB)),
                    ("Elapsed", process.elapsed),
                ])
                sectionBox("Command Line") {
                    rawText(process.arguments)
                }
                focusedInspectionPane
            } else {
                placeholderPane("Select a process.")
            }
        }
    }

    private func diskFilePane(_ diagnostic: DiskDiagnostic) -> some View {
        HSplitView {
            Table(diagnostic.files, selection: Binding(
                get: { selectedFilePath },
                set: {
                    selectedFilePath = $0
                    focusedTitle = nil
                    focusedOutput = ""
                }
            )) {
                TableColumn("Size") { file in
                    Text(formatBytes(file.size))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 90, ideal: 110)
                TableColumn("Modified") { file in
                    Text(file.modified)
                        .font(.caption.monospacedDigit())
                }
                .width(min: 130, ideal: 150)
                TableColumn("Owner") { file in
                    Text(file.owner)
                        .font(.caption)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 110)
                TableColumn("Path") { file in
                    Text(file.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(12)
            .frame(minWidth: 560)

            selectedDiskFileDetail(diagnostic.files)
                .padding(12)
                .frame(minWidth: 340)
        }
    }

    private func selectedDiskFileDetail(_ files: [DiskFileDiagnosticRow]) -> some View {
        let file = selectedFilePath.flatMap { path in files.first { $0.path == path } }
        return VStack(alignment: .leading, spacing: 10) {
            if let file {
                HStack {
                    Text(file.fileName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        Task {
                            await runFocusedInspection(
                                title: "Directory \(file.directory)",
                                script: Self.directoryInspectionScript(path: file.directory)
                            )
                        }
                    } label: {
                        Label("Inspect Directory", systemImage: "folder.badge.gearshape")
                    }
                    .disabled(focusedLoading)
                }
                keyValuePane([
                    ("Size", formatBytes(file.size)),
                    ("Modified", file.modified),
                    ("Owner", file.owner),
                    ("Directory", file.directory),
                    ("Path", file.path),
                ])
                focusedInspectionPane
            } else {
                placeholderPane("Select a file.")
            }
        }
    }

    private func systemdFilesPane(_ diagnostic: SystemdDiagnostic) -> some View {
        HSplitView {
            List(diagnostic.files, selection: Binding(
                get: { selectedSystemdFileId },
                set: { selectedSystemdFileId = $0 }
            )) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.kind)
                        .font(.caption.weight(.semibold))
                    Text(file.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 3)
            }
            .frame(minWidth: 280, idealWidth: 340)

            if let file = selectedSystemdFileId.flatMap({ id in diagnostic.files.first { $0.id == id } }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(file.path)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    rawPane(file.content)
                }
                .padding(12)
                .frame(minWidth: 420)
            } else {
                placeholderPane("Select a unit, drop-in, or environment file.")
            }
        }
    }

    private func systemdJournalPane(_ diagnostic: SystemdDiagnostic) -> some View {
        HSplitView {
            keyValuePane(diagnostic.properties)
                .padding(12)
                .frame(minWidth: 340)
            sectionBox("Recent Journal") {
                rawText(diagnostic.journalLines.joined(separator: "\n"))
            }
            .padding(12)
            .frame(minWidth: 440)
        }
    }

    @ViewBuilder
    private func serviceSpecificPane(_ diagnostic: SystemdDiagnostic) -> some View {
        if diagnostic.serviceFamily != .generic || !diagnostic.serviceGroups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: diagnostic.serviceFamily.icon)
                        .foregroundStyle(.secondary)
                    Text(diagnostic.serviceFamily.title)
                        .font(.headline)
                    Spacer()
                    if !diagnostic.serviceFamily.description.isEmpty {
                        Text(diagnostic.serviceFamily.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !diagnostic.serviceGroups.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                        ForEach(diagnostic.serviceGroups) { group in
                            serviceGroupBox(group)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func serviceGroupBox(_ group: ServiceDiagnosticGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if !group.rows.isEmpty {
                inlineKeyValueRows(group.rows)
            }

            if !group.lines.isEmpty {
                rawText(group.lines.joined(separator: "\n"))
                    .frame(minHeight: 80, maxHeight: 180)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func ufwRulesPane(_ diagnostic: UFWDiagnostic) -> some View {
        HSplitView {
            Table(diagnostic.rules, selection: Binding(
                get: { selectedUFWRuleId },
                set: { selectedUFWRuleId = $0 }
            )) {
                TableColumn("#") { rule in
                    Text("\(rule.number)")
                        .font(.caption.monospacedDigit())
                }
                .width(min: 45, ideal: 55)
                TableColumn("Action") { rule in
                    Text(rule.action)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(rule.action.localizedCaseInsensitiveContains("deny") ? .red : .green)
                }
                .width(min: 80, ideal: 110)
                TableColumn("Target") { rule in
                    Text(rule.target)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
                .width(min: 150, ideal: 220)
                TableColumn("Source") { rule in
                    Text(rule.source)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(12)
            .frame(minWidth: 560)

            if let rule = selectedUFWRuleId.flatMap({ id in diagnostic.rules.first { $0.id == id } }) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Rule \(rule.number)")
                        .font(.headline)
                    keyValuePane([
                        ("Action", rule.action),
                        ("Target", rule.target),
                        ("Source", rule.source),
                        ("Raw", rule.raw),
                    ])
                    Button {
                        Task {
                            await runFocusedInspection(
                                title: "UFW Source \(rule.source)",
                                script: Self.ufwSourceInspectionScript(source: rule.source)
                            )
                        }
                    } label: {
                        Label("Inspect Source", systemImage: "network")
                    }
                    .disabled(focusedLoading)
                    focusedInspectionPane
                }
                .padding(12)
                .frame(minWidth: 340)
            } else {
                placeholderPane("Select a UFW rule.")
            }
        }
    }

    private func ufwBlockedSourcesPane(_ diagnostic: UFWDiagnostic) -> some View {
        HSplitView {
            List(diagnostic.blockedSources, id: \.self, selection: Binding(
                get: { selectedUFWSource },
                set: {
                    selectedUFWSource = $0
                    focusedTitle = nil
                    focusedOutput = ""
                }
            )) { source in
                Text(source)
                    .font(.caption.monospaced())
            }
            .frame(minWidth: 220, idealWidth: 280)

            VStack(alignment: .leading, spacing: 10) {
                if let source = selectedUFWSource {
                    HStack {
                        Text(source)
                            .font(.headline)
                        Spacer()
                        Button {
                            Task {
                                await runFocusedInspection(
                                    title: "Blocked Source \(source)",
                                    script: Self.ufwSourceInspectionScript(source: source)
                                )
                            }
                        } label: {
                            Label("Inspect Source", systemImage: "network")
                        }
                        .disabled(focusedLoading)
                    }
                    sectionBox("Related Logs") {
                        rawText(diagnostic.logs.filter { $0.contains(source) }.joined(separator: "\n"))
                    }
                    focusedInspectionPane
                } else {
                    sectionBox("Recent Blocks") {
                        rawText(diagnostic.logs.joined(separator: "\n"))
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 520)
        }
    }

    // MARK: - Shared UI

    private func overviewPane(_ items: [(String, String)], warnings: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewCards(items)
                if !warnings.isEmpty {
                    warningList(warnings)
                }
            }
            .padding(16)
        }
    }

    private func overviewCards(_ items: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.1)
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func warningList(_ warnings: [String]) -> some View {
        sectionBox("Warnings") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func keyValuePane(_ rows: [(String, String)]) -> some View {
        ScrollView {
            inlineKeyValueRows(rows)
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func inlineKeyValueRows(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(row.1.isEmpty ? "-" : row.1)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func sectionBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func rawText(_ text: String) -> some View {
        ScrollView {
            Text(text.isEmpty ? "No data." : text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func rawPane(_ text: String) -> some View {
        rawText(text.isEmpty && !isLoading ? "No output." : text)
            .padding(16)
    }

    private func placeholderPane(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var focusedInspectionPane: some View {
        if focusedLoading {
            ProgressView("Inspecting...")
                .controlSize(.small)
        } else if !focusedOutput.isEmpty || focusedTitle != nil {
            sectionBox(focusedTitle ?? "Inspection") {
                rawText(focusedOutput)
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func formatKilobytes(_ kilobytes: UInt64) -> String {
        formatBytes(kilobytes.multipliedWithoutOverflow(by: 1024))
    }

    private func diagnosticScript() -> String {
        switch drillDown {
        case .cpu:
            return Self.cpuScript
        case .memory:
            return Self.memoryScript
        case .disk(let disk):
            return Self.diskScript(mount: disk.mount)
        case .systemdService(let unit):
            return Self.systemdScript(unit: unit)
        case .ufw:
            return Self.ufwScript(sshPort: sshPort)
        }
    }

    private static let cpuScript = """
    set +e
    export LC_ALL=C

    printf 'INFO\tLoad\t%s\n' "$(uptime 2>/dev/null || true)"
    if command -v nproc >/dev/null 2>&1; then
      printf 'INFO\tCores\t%s\n' "$(nproc 2>/dev/null || true)"
    elif command -v sysctl >/dev/null 2>&1; then
      printf 'INFO\tCores\t%s\n' "$(sysctl -n hw.ncpu 2>/dev/null || true)"
    fi
    if command -v mpstat >/dev/null 2>&1; then
      mpstat 1 1 2>/dev/null | awk 'NF {print "SUMMARY\t" $0}' || true
    fi

    emit_cpu_processes() {
      awk '
        BEGIN { OFS="\t"; count=0 }
        NF >= 8 && count < 35 {
          args=$9
          for (i=10; i<=NF; i++) args=args " " $i
          print "PROC",$1,$2,$3,$4,$5,$6,$7,0,0,$8,args
          count++
        }
      '
    }

    if out=$(ps -eo pid=,ppid=,user=,stat=,comm=,pcpu=,pmem=,etime=,args= --sort=-pcpu 2>/dev/null); then
      printf '%s\n' "$out" | emit_cpu_processes
    elif out=$(ps axo pid=,ppid=,user=,stat=,comm=,%cpu=,%mem=,etime=,command= -r 2>/dev/null); then
      printf '%s\n' "$out" | emit_cpu_processes
    else
      printf 'WARN\tCould not collect process CPU data.\n'
    fi

    if out=$(ps -eLo pid,tid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null); then
      printf '%s\n' "$out" | awk '
        BEGIN { OFS="\t"; count=0 }
        NR > 1 && NF >= 5 && count < 35 {
          print "THREAD",$1,$2,$3,$4,$5
          count++
        }
      '
    else
      printf 'WARN\tThread-level CPU data is unavailable on this host.\n'
    fi
    """

    private static let memoryScript = """
    set +e
    export LC_ALL=C

    if command -v free >/dev/null 2>&1; then
      free -h 2>/dev/null | awk 'NF {print "SUMMARY\t" $0}' || true
    elif command -v vm_stat >/dev/null 2>&1; then
      vm_stat 2>/dev/null | awk 'NF {print "SUMMARY\t" $0}' || true
      sysctl hw.memsize 2>/dev/null | awk 'NF {print "SUMMARY\t" $0}' || true
    else
      printf 'WARN\tNo memory summary command found.\n'
    fi

    emit_memory_processes() {
      awk '
        BEGIN { OFS="\t"; count=0 }
        NF >= 10 && count < 35 {
          args=$11
          for (i=12; i<=NF; i++) args=args " " $i
          print "PROC",$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,args
          count++
        }
      '
    }

    if out=$(ps -eo pid=,ppid=,user=,stat=,comm=,pcpu=,pmem=,rss=,vsz=,etime=,args= --sort=-rss 2>/dev/null); then
      printf '%s\n' "$out" | emit_memory_processes
    elif out=$(ps axo pid=,ppid=,user=,stat=,comm=,%cpu=,%mem=,rss=,vsz=,etime=,command= -m 2>/dev/null); then
      printf '%s\n' "$out" | emit_memory_processes
    else
      printf 'WARN\tCould not collect process memory data.\n'
    fi

    if command -v journalctl >/dev/null 2>&1; then
      sudo -n journalctl -k -n 300 --no-pager 2>/dev/null \
        | grep -Ei 'out of memory|oom|killed process|memory pressure' \
        | tail -n 40 \
        | awk 'NF {print "EVENT\t" $0}' || true
    elif command -v dmesg >/dev/null 2>&1; then
      sudo -n dmesg 2>/dev/null \
        | grep -Ei 'out of memory|oom|killed process|memory pressure' \
        | tail -n 40 \
        | awk 'NF {print "EVENT\t" $0}' || true
    else
      printf 'WARN\tKernel memory-pressure logs are unavailable.\n'
    fi
    """

    private static func diskScript(mount: String) -> String {
        let quotedMount = RemoteCommandRunner.shellQuote(mount)
        return """
        set +e
        export LC_ALL=C
        mount_path=\(quotedMount)

        usage=$(df -hP "$mount_path" 2>/dev/null | awk 'NR==2 {print $0}' || true)
        [ -n "$usage" ] || usage=$(df -h "$mount_path" 2>/dev/null | awk 'NR==2 {print $0}' || true)
        printf 'MOUNT\t%s\t%s\n' "$mount_path" "$usage"

        if ! command -v find >/dev/null 2>&1; then
          printf 'WARN\tfind is not available on this host.\n'
          exit 0
        fi

        out="${TMPDIR:-/tmp}/midnight-ssh-files-$$.tsv"
        err="${TMPDIR:-/tmp}/midnight-ssh-files-$$.err"
        trap 'rm -f "$out" "$err"' EXIT
        : > "$out"
        : > "$err"

        find_flags=""
        if find "$mount_path" -xdev -type f -mtime -14 -print -quit >/dev/null 2>&1; then
          find_flags="-xdev"
        fi

        if find "$mount_path" $find_flags -maxdepth 0 -printf '' >/dev/null 2>&1; then
          find "$mount_path" $find_flags -type f -mtime -14 -printf 'FILE\t%s\t%T@\t%TY-%Tm-%Td %TH:%TM\t%u\t%h\t%p\n' > "$out" 2>"$err"
        elif stat -f '%z' "$mount_path" >/dev/null 2>&1; then
          find "$mount_path" $find_flags -type f -mtime -14 -exec stat -f 'FILE\t%z\t%m\t%Sm\t%Su\t%N' -t '%Y-%m-%d %H:%M' {} + > "$out" 2>"$err"
        else
          find "$mount_path" $find_flags -type f -mtime -14 -exec ls -ln {} + 2>"$err" \
            | awk 'BEGIN { OFS="\t" } NF >= 9 { path=$9; for (i=10; i<=NF; i++) path=path " " $i; print "FILE",$5,0,$6 " " $7 " " $8,$3,"",path }' > "$out"
        fi

        if [ -s "$out" ]; then
          sort -nr -k2,2 "$out" | head -n 120
        else
          printf 'WARN\tNo files changed in the last 14 days were found on this mount, or the current user cannot read them.\n'
        fi
        if [ -s "$err" ]; then
          printf 'WARN\tSome paths could not be read while scanning this mount.\n'
        fi
        """
    }

    private static func systemdScript(unit: String) -> String {
        let quotedUnit = RemoteCommandRunner.shellQuote(unit)
        return """
        set +e
        export LC_ALL=C
        unit=\(quotedUnit)

        command -v systemctl >/dev/null 2>&1 || { printf 'WARN\tsystemctl is not available on this host.\n'; exit 127; }

        show_unit() {
          systemctl show "$unit" --no-pager "$@" 2>&1 || sudo -n systemctl show "$unit" --no-pager "$@" 2>&1 || true
        }

        emit_show() {
          show_unit "$@" | awk -F= 'BEGIN { OFS="\t" } NF { key=$1; sub(/^[^=]*=/, ""); print "KV",key,$0 }'
        }

        emit_family() {
          printf 'SVCFAMILY\t%s\n' "$1"
        }

        emit_svc() {
          printf 'SVC\t%s\t%s\t%s\n' "$1" "$2" "$3"
        }

        emit_lines() {
          section="$1"
          shift
          "$@" 2>&1 | awk -v section="$section" 'BEGIN { OFS="\t" } NF { print "SVCLINE",section,$0 }'
        }

        emit_shell_lines() {
          section="$1"
          script="$2"
          sh -lc "$script" 2>&1 | awk -v section="$section" 'BEGIN { OFS="\t" } NF { print "SVCLINE",section,$0 }'
        }

        emit_file() {
          kind="$1"
          file="$2"
          [ -n "$file" ] || return 0
          printf 'FILE\t%s\t%s\n' "$kind" "$file"
          (sudo -n sed -n '1,240p' "$file" 2>&1 || sed -n '1,240p' "$file" 2>&1 || true) \
            | awk -v kind="$kind" -v file="$file" 'BEGIN { OFS="\t" } { print "FILELINE",kind,file,NR,$0 }'
        }

        emit_show \
          -p Id -p Names -p Description -p LoadState -p ActiveState -p SubState \
          -p User -p Group -p DynamicUser -p SupplementaryGroups \
          -p MainPID -p ExecMainPID -p ExecMainStatus -p Restart -p RestartUSec \
          -p WorkingDirectory -p FragmentPath -p DropInPaths \
          -p Environment -p EnvironmentFiles \
          -p ExecStart -p ExecReload -p ExecStop -p ExecStartPre -p ExecStartPost

        fragment=$(systemctl show "$unit" --no-pager --value -p FragmentPath 2>/dev/null || sudo -n systemctl show "$unit" --no-pager --value -p FragmentPath 2>/dev/null || true)
        emit_file "Unit File" "$fragment"

        dropins=$(systemctl show "$unit" --no-pager --value -p DropInPaths 2>/dev/null || sudo -n systemctl show "$unit" --no-pager --value -p DropInPaths 2>/dev/null || true)
        if [ -n "$dropins" ]; then
          for file in $dropins; do
            emit_file "Drop-in" "$file"
          done
        fi

        env_files=$(systemctl show "$unit" --no-pager --value -p EnvironmentFiles 2>/dev/null || sudo -n systemctl show "$unit" --no-pager --value -p EnvironmentFiles 2>/dev/null || true)
        if [ -n "$env_files" ]; then
          for file in $env_files; do
            file=${file#-}
            emit_file "Environment File" "$file"
          done
        fi

        if command -v journalctl >/dev/null 2>&1; then
          (journalctl -u "$unit" -n 160 --no-pager -o short-iso 2>&1 || sudo -n journalctl -u "$unit" -n 160 --no-pager -o short-iso 2>&1 || true) \
            | awk 'BEGIN { OFS="\t" } NF { print "JOURNAL",$0 }'
        else
          printf 'WARN\tjournalctl is not available on this host.\n'
        fi

        service_key=$(printf '%s' "$unit" | tr '[:upper:]' '[:lower:]')
        case "$service_key" in
          *nginx*|*apache2*|*httpd*)
            emit_family web
            if command -v nginx >/dev/null 2>&1; then
              emit_shell_lines "Config Test" "nginx -t"
              emit_shell_lines "Virtual Hosts" "nginx -T 2>/dev/null | awk '/^[[:space:]]*(server_name|listen)[[:space:]]/ {print}' | head -n 160"
            elif command -v apachectl >/dev/null 2>&1; then
              emit_shell_lines "Config Test" "apachectl configtest"
              emit_shell_lines "Virtual Hosts" "apachectl -S 2>&1 | head -n 180"
            fi
            emit_shell_lines "Listeners" "ss -ltnp 2>/dev/null | grep -Ei '(:80|:443|nginx|apache|httpd)' || netstat -ltnp 2>/dev/null | grep -Ei '(:80|:443|nginx|apache|httpd)' || true"
            emit_shell_lines "TLS Certificates" "find /etc/letsencrypt/live /etc/ssl -maxdepth 3 -type f \\( -name fullchain.pem -o -name cert.pem -o -name '*.crt' \\) 2>/dev/null | head -n 60 | while read -r cert; do end=$(openssl x509 -noout -enddate -in \"$cert\" 2>/dev/null | sed 's/^notAfter=//'); [ -n \"$end\" ] && printf '%s -> %s\\n' \"$cert\" \"$end\"; done"
            ;;
          *apparmor*)
            emit_family apparmor
            emit_shell_lines "Profile State" "aa-status 2>/dev/null || apparmor_status 2>/dev/null || true"
            emit_shell_lines "Recent Denials" "(journalctl -k -n 600 --no-pager 2>/dev/null || dmesg 2>/dev/null || true) | grep -Ei 'apparmor=.*DENIED|audit.*DENIED' | tail -n 120"
            ;;
          *fail2ban*)
            emit_family fail2ban
            emit_shell_lines "Jails" "fail2ban-client status 2>/dev/null || sudo -n fail2ban-client status 2>/dev/null || true"
            emit_shell_lines "Bans" "status=$(fail2ban-client status 2>/dev/null || sudo -n fail2ban-client status 2>/dev/null || true); jails=$(printf '%s\\n' \"$status\" | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); for jail in $jails; do jail=$(printf '%s' \"$jail\" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); [ -n \"$jail\" ] || continue; echo \"-- $jail --\"; fail2ban-client status \"$jail\" 2>/dev/null || sudo -n fail2ban-client status \"$jail\" 2>/dev/null || true; done"
            emit_shell_lines "Recent Log" "tail -n 160 /var/log/fail2ban.log 2>/dev/null || journalctl -u fail2ban -n 160 --no-pager 2>/dev/null || true"
            ;;
          *apt-daily*|*unattended-upgrades*|*apt*)
            emit_family apt
            emit_shell_lines "Timers" "systemctl list-timers '*apt*' '*unattended*' --all --no-pager 2>/dev/null || true"
            emit_shell_lines "Recent Package Activity" "tail -n 160 /var/log/apt/history.log /var/log/apt/term.log /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null"
            emit_shell_lines "Locks" "lslocks 2>/dev/null | grep -E 'apt|dpkg|unattended' || true"
            ;;
          *certbot*|*letsencrypt*)
            emit_family certbot
            emit_shell_lines "Certificates" "certbot certificates 2>/dev/null || sudo -n certbot certificates 2>/dev/null || true"
            emit_shell_lines "Renewal Timers" "systemctl list-timers '*certbot*' '*letsencrypt*' --all --no-pager 2>/dev/null || true"
            emit_shell_lines "Renewal Logs" "tail -n 180 /var/log/letsencrypt/letsencrypt.log 2>/dev/null || journalctl -u certbot -n 180 --no-pager 2>/dev/null || true"
            ;;
          *chrony*|*timesyncd*|*ntp*)
            emit_family chrony
            emit_shell_lines "Tracking" "chronyc tracking 2>/dev/null || timedatectl 2>/dev/null || true"
            emit_shell_lines "Sources" "chronyc sources -v 2>/dev/null || timedatectl timesync-status 2>/dev/null || true"
            emit_shell_lines "Recent Sync Logs" "journalctl -u chrony -u chronyd -u systemd-timesyncd -n 140 --no-pager 2>/dev/null || true"
            ;;
          *clamav*|*clamd*|*freshclam*)
            emit_family clamav
            emit_shell_lines "Version" "clamdscan --version 2>/dev/null || clamscan --version 2>/dev/null || freshclam --version 2>/dev/null || true"
            emit_shell_lines "Definitions" "ls -lh /var/lib/clamav 2>/dev/null || true"
            emit_shell_lines "Recent Logs" "tail -n 180 /var/log/clamav/clamav.log /var/log/clamav/freshclam.log 2>/dev/null || journalctl -u clamav-daemon -u clamav-freshclam -n 180 --no-pager 2>/dev/null || true"
            ;;
          *containerd*|*docker*)
            emit_family container
            emit_shell_lines "Runtime" "ctr version 2>/dev/null || docker version --format '{{.Server.Version}}' 2>/dev/null || true"
            emit_shell_lines "Containers" "ctr namespaces list 2>/dev/null; ctr -n default containers list 2>/dev/null | head -n 120; docker ps -a --format 'table {{.Names}}\\t{{.Status}}\\t{{.Image}}' 2>/dev/null | head -n 120"
            emit_shell_lines "Disk Usage" "docker system df 2>/dev/null || du -sh /var/lib/containerd /var/lib/docker 2>/dev/null || true"
            ;;
          *dovecot*)
            emit_family mail
            emit_shell_lines "Dovecot Config" "doveconf -n 2>/dev/null | head -n 180 || true"
            emit_shell_lines "Mail Listeners" "ss -ltnp 2>/dev/null | grep -E ':(143|993|110|995)\\b|dovecot' || true"
            emit_shell_lines "Auth Failures" "(journalctl -u dovecot -n 600 --no-pager 2>/dev/null || tail -n 600 /var/log/mail.log 2>/dev/null || true) | grep -Ei 'auth.*fail|failed password|Disconnected.*auth' | tail -n 120"
            ;;
          *postfix*)
            emit_family mail
            emit_shell_lines "Queue" "postqueue -p 2>/dev/null || mailq 2>/dev/null || true"
            emit_shell_lines "Postfix Config" "postconf -n 2>/dev/null | head -n 180 || true"
            emit_shell_lines "Mail Flow" "(journalctl -u postfix -n 700 --no-pager 2>/dev/null || tail -n 700 /var/log/mail.log 2>/dev/null || true) | grep -Ei 'status=(sent|deferred|bounced)|reject|warning|fatal|connect from' | tail -n 160"
            ;;
          *rsyslog*|*journald*)
            emit_family syslog
            emit_shell_lines "Config Validation" "rsyslogd -N1 2>&1 || true"
            emit_shell_lines "Rules And Targets" "grep -RhsE '^[^#].*(@@?|/var/log|omfwd|imjournal|imuxsock)' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null | head -n 160"
            emit_shell_lines "Log Disk Usage" "du -sh /var/log/* 2>/dev/null | sort -hr | head -n 80"
            ;;
          *snapd*|*snap*)
            emit_family snap
            emit_shell_lines "Refreshes" "snap changes 2>/dev/null | head -n 120 || true"
            emit_shell_lines "Installed Snaps" "snap list 2>/dev/null | head -n 160 || true"
            emit_shell_lines "Snap Services" "snap services 2>/dev/null | head -n 160 || true"
            ;;
          *ssh*|*sshd*)
            emit_family ssh
            emit_shell_lines "Listeners And Sessions" "ss -ltnp 2>/dev/null | grep -E ':22\\b|sshd' || true; who 2>/dev/null || true"
            emit_shell_lines "Auth Activity" "(journalctl -u ssh -u sshd -n 700 --no-pager 2>/dev/null || tail -n 700 /var/log/auth.log /var/log/secure 2>/dev/null || true) | grep -Ei 'Accepted|Failed|Invalid user|Disconnected|Unable to negotiate' | tail -n 160"
            emit_shell_lines "Effective Config" "sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|challengeresponseauthentication|allowusers|denyusers|authenticationmethods|maxauthtries)' || true"
            ;;
          *)
            emit_family generic
            emit_shell_lines "Listeners" "mainpid=$(systemctl show \"$unit\" --value -p MainPID 2>/dev/null || true); [ -n \"$mainpid\" ] && [ \"$mainpid\" != 0 ] && ss -ltnp 2>/dev/null | grep -F \"pid=$mainpid,\" || true"
            emit_shell_lines "Recent Warnings" "journalctl -u \"$unit\" -n 300 --no-pager 2>/dev/null | grep -Ei 'error|warn|fail|fatal|denied|timeout' | tail -n 80 || true"
            ;;
        esac
        """
    }

    private static func ufwScript(sshPort: UInt16?) -> String {
        let sshPortValue = sshPort.map { String($0) } ?? "22"
        return """
        set +e
        export LC_ALL=C

        printf 'INFO\tSSHPort\t\(sshPortValue)\n'
        command -v ufw >/dev/null 2>&1 || { printf 'WARN\tufw is not available on this host.\n'; exit 127; }

        run_ufw() {
          sudo -n ufw "$@" 2>&1 || ufw "$@" 2>&1 || true
        }

        run_ufw status verbose | awk 'NF {print "STATUS\t" $0}'
        run_ufw status numbered | awk 'NF {print "RULE\t" $0}'
        run_ufw app list | awk 'NF {print "APP\t" $0}'

        (sudo -n sh -c 'printf "%s\n" "--- /etc/default/ufw ---"; sed -n "1,220p" /etc/default/ufw 2>/dev/null; printf "%s\n" "--- /etc/ufw/ufw.conf ---"; sed -n "1,220p" /etc/ufw/ufw.conf 2>/dev/null' 2>&1 \
          || sh -c 'printf "%s\n" "--- /etc/default/ufw ---"; sed -n "1,220p" /etc/default/ufw 2>/dev/null; printf "%s\n" "--- /etc/ufw/ufw.conf ---"; sed -n "1,220p" /etc/ufw/ufw.conf 2>/dev/null' 2>&1 \
          || true) | awk 'NF {print "CONFIG\t" $0}'

        if sudo -n test -r /var/log/ufw.log 2>/dev/null; then
          sudo -n tail -n 180 /var/log/ufw.log 2>/dev/null
        elif [ -r /var/log/ufw.log ]; then
          tail -n 180 /var/log/ufw.log 2>/dev/null
        elif command -v journalctl >/dev/null 2>&1; then
          sudo -n journalctl -k -n 360 --no-pager 2>/dev/null | grep -E '\\[UFW (BLOCK|DENY)\\]' | tail -n 180 || true
        elif command -v dmesg >/dev/null 2>&1; then
          sudo -n dmesg 2>/dev/null | grep -E '\\[UFW (BLOCK|DENY)\\]' | tail -n 180 || true
        else
          printf 'WARN\tNo UFW log source found.\n'
        fi | awk 'NF {print "LOG\t" $0}'

        sudo -n iptables -S 2>&1 | sed -n '1,260p' | awk 'NF {print "IPTABLES\t" $0}' || true
        sudo -n ip6tables -S 2>&1 | sed -n '1,260p' | awk 'NF {print "IPTABLES6\t" $0}' || true
        """
    }

    private static func processInspectionScript(pid: Int) -> String {
        """
        set +e
        export LC_ALL=C
        pid=\(pid)
        echo "== Process =="
        ps -fp "$pid" 2>/dev/null || ps -p "$pid" -o pid,ppid,user,stat,comm,pcpu,pmem,etime,args 2>/dev/null || true
        echo
        echo "== /proc status =="
        [ -r "/proc/$pid/status" ] && sed -n '1,220p' "/proc/$pid/status" || echo "/proc status unavailable."
        echo
        echo "== Open files =="
        if command -v lsof >/dev/null 2>&1; then
          lsof -p "$pid" 2>/dev/null | head -n 80 || true
        elif [ -d "/proc/$pid/fd" ]; then
          ls -la "/proc/$pid/fd" 2>/dev/null | head -n 80 || true
        else
          echo "Open-file inspection unavailable."
        fi
        echo
        echo "== Network sockets =="
        if command -v ss >/dev/null 2>&1; then
          ss -tunap 2>/dev/null | grep -F "pid=$pid," | head -n 80 || true
        elif command -v netstat >/dev/null 2>&1; then
          netstat -tunap 2>/dev/null | grep -F "/$pid" | head -n 80 || true
        else
          echo "Socket inspection unavailable."
        fi
        """
    }

    private static func directoryInspectionScript(path: String) -> String {
        let quotedPath = RemoteCommandRunner.shellQuote(path)
        return """
        set +e
        export LC_ALL=C
        dir=\(quotedPath)
        echo "== Directory Usage =="
        if du -h -d 1 "$dir" >/dev/null 2>&1; then
          du -h -d 1 "$dir" 2>/dev/null | sort -hr | head -n 80
        elif du -h --max-depth=1 "$dir" >/dev/null 2>&1; then
          du -h --max-depth=1 "$dir" 2>/dev/null | sort -hr | head -n 80
        else
          du -h "$dir"/* 2>/dev/null | sort -hr | head -n 80 || true
        fi
        echo
        echo "== Recently Changed In Directory =="
        find "$dir" -maxdepth 1 -type f -mtime -14 -exec ls -lh {} + 2>/dev/null | sort -k6,8 | tail -n 80 || true
        """
    }

    private static func ufwSourceInspectionScript(source: String) -> String {
        let quotedSource = RemoteCommandRunner.shellQuote(source)
        return """
        set +e
        export LC_ALL=C
        source_ip=\(quotedSource)
        echo "== Source =="
        printf '%s\n' "$source_ip"
        echo
        echo "== Reverse DNS =="
        (command -v dig >/dev/null 2>&1 && dig +short -x "$source_ip") || (command -v host >/dev/null 2>&1 && host "$source_ip") || echo "Reverse lookup unavailable."
        echo
        echo "== Recent UFW log lines =="
        if sudo -n test -r /var/log/ufw.log 2>/dev/null; then
          sudo -n grep -F "SRC=$source_ip" /var/log/ufw.log 2>/dev/null | tail -n 120
        elif [ -r /var/log/ufw.log ]; then
          grep -F "SRC=$source_ip" /var/log/ufw.log 2>/dev/null | tail -n 120
        elif command -v journalctl >/dev/null 2>&1; then
          sudo -n journalctl -k -n 1000 --no-pager 2>/dev/null | grep -F "SRC=$source_ip" | tail -n 120 || true
        else
          echo "No log source found."
        fi
        """
    }
}

// MARK: - Monitor diagnostic data

private enum DrillDownMode: String, CaseIterable {
    case overview = "Overview"
    case hotspots = "Hotspots"
    case details = "Details"
    case raw = "Raw"
}

private enum MonitorDiagnosticSnapshot {
    case cpu(CPUDiagnostic)
    case memory(MemoryDiagnostic)
    case disk(DiskDiagnostic)
    case systemd(SystemdDiagnostic)
    case ufw(UFWDiagnostic)
}

private struct ProcessDiagnosticRow: Identifiable {
    let pid: Int
    let ppid: Int
    let user: String
    let state: String
    let command: String
    let cpuPercent: Double
    let memoryPercent: Double
    let rssKB: UInt64
    let vszKB: UInt64
    let elapsed: String
    let arguments: String

    var id: Int { pid }
}

private struct ThreadDiagnosticRow: Identifiable {
    let pid: Int
    let threadId: String
    let cpuPercent: Double
    let memoryPercent: Double
    let command: String

    var id: String { "\(pid):\(threadId)" }
}

private struct CPUDiagnostic {
    var load = ""
    var cores = ""
    var summary: [String] = []
    var processes: [ProcessDiagnosticRow] = []
    var threads: [ThreadDiagnosticRow] = []
    var warnings: [String] = []
}

private struct MemoryDiagnostic {
    var summary: [String] = []
    var processes: [ProcessDiagnosticRow] = []
    var events: [String] = []
    var warnings: [String] = []
}

private struct DiskDiagnostic {
    var mount = ""
    var usage = ""
    var files: [DiskFileDiagnosticRow] = []
    var warnings: [String] = []
}

private struct DiskFileDiagnosticRow: Identifiable {
    let size: UInt64
    let modifiedEpoch: Double
    let modified: String
    let owner: String
    let directory: String
    let path: String

    var id: String { path }

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent.isEmpty
            ? path
            : URL(fileURLWithPath: path).lastPathComponent
    }
}

private struct SystemdDiagnostic {
    var properties: [(String, String)] = []
    var files: [SystemdFileDiagnostic] = []
    var journalLines: [String] = []
    var warnings: [String] = []
    var serviceFamily = LinuxServiceFamily.generic
    var serviceGroups: [ServiceDiagnosticGroup] = []

    func value(for key: String) -> String? {
        properties.first { $0.0 == key }?.1
    }

    mutating func appendServiceRow(section: String, label: String, value: String) {
        let index = serviceGroupIndex(for: section)
        serviceGroups[index].rows.append((label, value))
    }

    mutating func appendServiceLine(section: String, line: String) {
        let index = serviceGroupIndex(for: section)
        serviceGroups[index].lines.append(line)
    }

    private mutating func serviceGroupIndex(for section: String) -> Int {
        let title = section.isEmpty ? "Service" : section
        if let index = serviceGroups.firstIndex(where: { $0.title == title }) {
            return index
        }
        serviceGroups.append(ServiceDiagnosticGroup(title: title))
        return serviceGroups.count - 1
    }
}

private struct SystemdFileDiagnostic: Identifiable {
    let kind: String
    let path: String
    var lines: [String]

    var id: String { "\(kind):\(path)" }
    var content: String { lines.joined(separator: "\n") }
}

private struct ServiceDiagnosticGroup: Identifiable {
    let title: String
    var rows: [(String, String)] = []
    var lines: [String] = []

    var id: String { title }
}

private enum LinuxServiceFamily: String {
    case generic
    case web
    case apparmor
    case fail2ban
    case apt
    case certbot
    case chrony
    case clamav
    case container
    case mail
    case syslog
    case snap
    case ssh

    var title: String {
        switch self {
        case .generic:  return "Generic Service"
        case .web:      return "Web Server"
        case .apparmor: return "AppArmor"
        case .fail2ban: return "Fail2ban"
        case .apt:      return "APT Automation"
        case .certbot:  return "Certificate Renewal"
        case .chrony:   return "Time Sync"
        case .clamav:   return "Malware Scanning"
        case .container:return "Container Runtime"
        case .mail:     return "Mail Service"
        case .syslog:   return "System Logging"
        case .snap:     return "Snap Packages"
        case .ssh:      return "SSH Access"
        }
    }

    var description: String {
        switch self {
        case .generic:  return ""
        case .web:      return "listeners, vhosts, TLS, config test"
        case .apparmor: return "profiles and denials"
        case .fail2ban: return "jails, bans, offenders"
        case .apt:      return "timers and package activity"
        case .certbot:  return "certificates and renewals"
        case .chrony:   return "offset, sources, sync health"
        case .clamav:   return "definitions and scan health"
        case .container:return "namespaces, containers, disk hints"
        case .mail:     return "queues, listeners, auth/mail logs"
        case .syslog:   return "pipeline validation and log targets"
        case .snap:     return "refreshes, snaps, services"
        case .ssh:      return "listeners, sessions, auth signals"
        }
    }

    var icon: String {
        switch self {
        case .generic:  return "switch.2"
        case .web:      return "network"
        case .apparmor: return "shield.lefthalf.filled"
        case .fail2ban: return "hand.raised"
        case .apt:      return "shippingbox"
        case .certbot:  return "lock.doc"
        case .chrony:   return "clock"
        case .clamav:   return "cross.case"
        case .container:return "cube.box"
        case .mail:     return "envelope"
        case .syslog:   return "doc.text.magnifyingglass"
        case .snap:     return "sparkles"
        case .ssh:      return "terminal"
        }
    }
}

private struct UFWDiagnostic {
    var info: [(String, String)] = []
    var statusLines: [String] = []
    var rules: [UFWDiagnosticRule] = []
    var logs: [String] = []
    var configLines: [String] = []
    var rawTables: [String] = []
    var warnings: [String] = []

    var blockedSources: [String] {
        let values = logs.compactMap { line -> String? in
            guard let range = line.range(of: "SRC=") else { return nil }
            let suffix = line[range.upperBound...]
            return suffix.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        return Array(Set(values)).sorted()
    }
}

private struct UFWDiagnosticRule: Identifiable {
    let id: Int
    let number: Int
    let target: String
    let action: String
    let source: String
    let raw: String
}

private enum MonitorDiagnosticParser {
    static func parse(_ output: String, kind: MonitorDrillDown) -> MonitorDiagnosticSnapshot {
        switch kind {
        case .cpu:
            return .cpu(parseCPU(output))
        case .memory:
            return .memory(parseMemory(output))
        case .disk:
            return .disk(parseDisk(output))
        case .systemdService:
            return .systemd(parseSystemd(output))
        case .ufw:
            return .ufw(parseUFW(output))
        }
    }

    private static func parseCPU(_ output: String) -> CPUDiagnostic {
        var diagnostic = CPUDiagnostic()
        for fields in records(output) {
            switch fields.first {
            case "INFO":
                guard fields.count >= 3 else { continue }
                if fields[1] == "Load" {
                    diagnostic.load = joined(fields, from: 2)
                } else if fields[1] == "Cores" {
                    diagnostic.cores = joined(fields, from: 2)
                }
            case "SUMMARY":
                diagnostic.summary.append(joined(fields, from: 1))
            case "PROC":
                if let row = parseProcess(fields) {
                    diagnostic.processes.append(row)
                }
            case "THREAD":
                if fields.count >= 6 {
                    diagnostic.threads.append(ThreadDiagnosticRow(
                        pid: int(fields[1]),
                        threadId: fields[2],
                        cpuPercent: double(fields[3]),
                        memoryPercent: double(fields[4]),
                        command: joined(fields, from: 5)
                    ))
                }
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            default:
                continue
            }
        }
        diagnostic.processes.sort { $0.cpuPercent > $1.cpuPercent }
        diagnostic.threads.sort { $0.cpuPercent > $1.cpuPercent }
        return diagnostic
    }

    private static func parseMemory(_ output: String) -> MemoryDiagnostic {
        var diagnostic = MemoryDiagnostic()
        for fields in records(output) {
            switch fields.first {
            case "SUMMARY":
                diagnostic.summary.append(joined(fields, from: 1))
            case "PROC":
                if let row = parseProcess(fields) {
                    diagnostic.processes.append(row)
                }
            case "EVENT":
                diagnostic.events.append(joined(fields, from: 1))
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            default:
                continue
            }
        }
        diagnostic.processes.sort { $0.rssKB > $1.rssKB }
        return diagnostic
    }

    private static func parseDisk(_ output: String) -> DiskDiagnostic {
        var diagnostic = DiskDiagnostic()
        for fields in records(output) {
            switch fields.first {
            case "MOUNT":
                diagnostic.mount = fields.count > 1 ? fields[1] : ""
                diagnostic.usage = fields.count > 2 ? joined(fields, from: 2) : ""
            case "FILE":
                if let row = parseDiskFile(fields) {
                    diagnostic.files.append(row)
                }
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            default:
                continue
            }
        }
        diagnostic.files.sort {
            if $0.size == $1.size {
                return $0.modifiedEpoch > $1.modifiedEpoch
            }
            return $0.size > $1.size
        }
        return diagnostic
    }

    private static func parseSystemd(_ output: String) -> SystemdDiagnostic {
        var diagnostic = SystemdDiagnostic()
        var fileOrder: [String] = []
        var filesById: [String: SystemdFileDiagnostic] = [:]

        for fields in records(output) {
            switch fields.first {
            case "KV":
                guard fields.count >= 3 else { continue }
                diagnostic.properties.append((fields[1], joined(fields, from: 2)))
            case "FILE":
                guard fields.count >= 3 else { continue }
                let file = SystemdFileDiagnostic(kind: fields[1], path: fields[2], lines: [])
                if filesById[file.id] == nil {
                    fileOrder.append(file.id)
                }
                filesById[file.id] = file
            case "FILELINE":
                guard fields.count >= 5 else { continue }
                let kind = fields[1]
                let path = fields[2]
                let id = "\(kind):\(path)"
                if filesById[id] == nil {
                    fileOrder.append(id)
                    filesById[id] = SystemdFileDiagnostic(kind: kind, path: path, lines: [])
                }
                filesById[id]?.lines.append(joined(fields, from: 4))
            case "JOURNAL":
                diagnostic.journalLines.append(joined(fields, from: 1))
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            case "SVCFAMILY":
                if fields.count >= 2 {
                    diagnostic.serviceFamily = LinuxServiceFamily(rawValue: fields[1]) ?? .generic
                }
            case "SVC":
                guard fields.count >= 4 else { continue }
                diagnostic.appendServiceRow(
                    section: fields[1],
                    label: fields[2],
                    value: joined(fields, from: 3)
                )
            case "SVCLINE":
                guard fields.count >= 3 else { continue }
                diagnostic.appendServiceLine(
                    section: fields[1],
                    line: joined(fields, from: 2)
                )
            default:
                continue
            }
        }

        diagnostic.files = fileOrder.compactMap { filesById[$0] }
        return diagnostic
    }

    private static func parseUFW(_ output: String) -> UFWDiagnostic {
        var diagnostic = UFWDiagnostic()
        var fallbackRuleId = 10_000

        for fields in records(output) {
            switch fields.first {
            case "INFO":
                guard fields.count >= 3 else { continue }
                diagnostic.info.append((fields[1], joined(fields, from: 2)))
            case "STATUS":
                diagnostic.statusLines.append(joined(fields, from: 1))
            case "RULE":
                let raw = joined(fields, from: 1)
                if let rule = parseUFWRule(raw, fallbackId: fallbackRuleId) {
                    diagnostic.rules.append(rule)
                    fallbackRuleId += 1
                }
            case "LOG":
                diagnostic.logs.append(joined(fields, from: 1))
            case "CONFIG":
                diagnostic.configLines.append(joined(fields, from: 1))
            case "IPTABLES", "IPTABLES6":
                diagnostic.rawTables.append(joined(fields, from: 1))
            case "WARN":
                diagnostic.warnings.append(joined(fields, from: 1))
            default:
                continue
            }
        }

        diagnostic.rules.sort { $0.number < $1.number }
        return diagnostic
    }

    private static func parseProcess(_ fields: [String]) -> ProcessDiagnosticRow? {
        guard fields.count >= 12 else { return nil }
        return ProcessDiagnosticRow(
            pid: int(fields[1]),
            ppid: int(fields[2]),
            user: fields[3],
            state: fields[4],
            command: fields[5],
            cpuPercent: double(fields[6]),
            memoryPercent: double(fields[7]),
            rssKB: uint(fields[8]),
            vszKB: uint(fields[9]),
            elapsed: fields[10],
            arguments: joined(fields, from: 11)
        )
    }

    private static func parseDiskFile(_ fields: [String]) -> DiskFileDiagnosticRow? {
        guard fields.count >= 6 else { return nil }
        let size = uint(fields[1])
        let modifiedEpoch = double(fields[2])
        let modified = fields[3]
        let owner = fields[4]

        let directory: String
        let path: String
        if fields.count >= 7 {
            directory = fields[5]
            path = joined(fields, from: 6)
        } else {
            path = joined(fields, from: 5)
            directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        }

        return DiskFileDiagnosticRow(
            size: size,
            modifiedEpoch: modifiedEpoch,
            modified: modified,
            owner: owner.isEmpty ? "-" : owner,
            directory: directory.isEmpty ? "/" : directory,
            path: path
        )
    }

    private static func parseUFWRule(_ raw: String, fallbackId: Int) -> UFWDiagnosticRule? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") else { return nil }

        let pattern = #"^\[\s*(\d+)\]\s+(.+?)\s{2,}(ALLOW(?:\s+(?:IN|OUT))?|DENY(?:\s+(?:IN|OUT))?|LIMIT(?:\s+(?:IN|OUT))?|REJECT(?:\s+(?:IN|OUT))?)\s{2,}(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges >= 5,
              let numberRange = Range(match.range(at: 1), in: trimmed),
              let targetRange = Range(match.range(at: 2), in: trimmed),
              let actionRange = Range(match.range(at: 3), in: trimmed),
              let sourceRange = Range(match.range(at: 4), in: trimmed)
        else {
            return UFWDiagnosticRule(
                id: fallbackId,
                number: fallbackId,
                target: trimmed,
                action: "Unknown",
                source: "",
                raw: raw
            )
        }

        let number = int(String(trimmed[numberRange]))
        return UFWDiagnosticRule(
            id: number,
            number: number,
            target: String(trimmed[targetRange]).trimmingCharacters(in: .whitespaces),
            action: String(trimmed[actionRange]).trimmingCharacters(in: .whitespaces),
            source: String(trimmed[sourceRange]).trimmingCharacters(in: .whitespaces),
            raw: raw
        )
    }

    private static func records(_ output: String) -> [[String]] {
        output
            .split(whereSeparator: \.isNewline)
            .map { line in
                String(line).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            }
    }

    private static func joined(_ fields: [String], from index: Int) -> String {
        guard fields.count > index else { return "" }
        return fields[index...].joined(separator: "\t")
    }

    private static func int(_ value: String) -> Int {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func uint(_ value: String) -> UInt64 {
        UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func double(_ value: String) -> Double {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

private extension UInt64 {
    func multipliedWithoutOverflow(by rhs: UInt64) -> UInt64 {
        let (value, overflow) = multipliedReportingOverflow(by: rhs)
        return overflow ? UInt64.max : value
    }
}

// MARK: - Connection world map

private struct ConnectionWorldMapView: View {
    let connectionId: String

    @State private var snapshot = RemoteIPMapSnapshot.empty
    @State private var isLoading = false
    @State private var lastError: String?

    private static let pollInterval: UInt64 = 60_000_000_000
    private static let maxGeolocatedIPs = 24
    private static let remoteAddressScript = """
    set +e

    emit_connected() {
      [ -n "$1" ] || return 0
      printf 'CONNECTED\\t%s\\n' "$1"
    }

    if [ -n "${SSH_CONNECTION:-}" ]; then
      set -- $SSH_CONNECTION
      emit_connected "$1"
    fi

    if [ -n "${SSH_CLIENT:-}" ]; then
      set -- $SSH_CLIENT
      emit_connected "$1"
    fi

    if command -v ss >/dev/null 2>&1; then
      ss -Htn state established 2>/dev/null | awk 'NF >= 5 {print "CONNECTED\\t" $NF}'
    elif command -v netstat >/dev/null 2>&1; then
      netstat -ant 2>/dev/null | awk 'toupper($0) ~ /ESTABLISHED/ && NF >= 5 {print "CONNECTED\\t" $(NF-1)}'
    fi

    if command -v fail2ban-client >/dev/null 2>&1; then
      f2b_status="$(sudo -n fail2ban-client status 2>/dev/null || fail2ban-client status 2>/dev/null || true)"
      jails="$(printf '%s\\n' "$f2b_status" | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ')"
      for jail in $jails; do
        jail="$(printf '%s' "$jail" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$jail" ] || continue
        (sudo -n fail2ban-client status "$jail" 2>/dev/null || fail2ban-client status "$jail" 2>/dev/null || true) \
          | sed -n 's/.*Banned IP list:[[:space:]]*//p' \
          | tr ' ' '\\n' \
          | awk 'NF {print "BANNED\\t" $1}'
      done
    fi

    if command -v ufw >/dev/null 2>&1; then
      if sudo -n test -r /var/log/ufw.log 2>/dev/null; then
        sudo -n tail -n 500 /var/log/ufw.log 2>/dev/null
      elif command -v journalctl >/dev/null 2>&1; then
        sudo -n journalctl -k -n 500 --no-pager 2>/dev/null
      else
        true
      fi | awk 'index($0, "[UFW BLOCK]") || index($0, "[UFW DENY]") {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^SRC=/) {
            sub(/^SRC=/, "", $i)
            print "BANNED\\t" $i
          }
        }
      }'
    fi
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "map")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Connection Map")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                } else if let updatedAt = snapshot.updatedAt {
                    Text(updatedAt.formatted(.dateTime.hour().minute().second()))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            WorldMapCanvas(points: snapshot.points)
                .frame(height: 132)
                .help("Public IP geolocation is approximate.")

            HStack(spacing: 12) {
                mapLegend(color: .green, label: "Connected", count: snapshot.connectedCount)
                mapLegend(color: .red, label: "Blocked", count: snapshot.bannedCount)
                Spacer()
                if snapshot.truncatedCount > 0 {
                    Text("+\(snapshot.truncatedCount) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if snapshot.connectedCount == 0 && snapshot.bannedCount == 0 && !isLoading {
                Text("No public connected or banned IPs found.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .task(id: connectionId) {
            await pollLoop()
        }
    }

    private func mapLegend(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(label) \(count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func pollLoop() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollInterval)
            await refresh()
        }
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await RemoteCommandRunner.runShell(
                connectionId: connectionId,
                script: Self.remoteAddressScript
            )
            let addresses = RemoteIPParser.parse(result.output)
            let sourceIPs = Self.cappedSourceIPs(
                connected: addresses.connected,
                banned: addresses.banned
            )
            let locations = await IPGeolocationService.shared.lookup(sourceIPs.visible)
            snapshot = RemoteIPMapSnapshot(
                connectedCount: addresses.connected.count,
                bannedCount: addresses.banned.count,
                truncatedCount: sourceIPs.truncated,
                points: makePoints(
                    connected: addresses.connected,
                    banned: addresses.banned,
                    locations: locations
                ),
                updatedAt: Date()
            )
            lastError = result.succeeded ? nil : "Remote IP scan exited with code \(result.exitCode)."
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func cappedSourceIPs(
        connected: [String],
        banned: [String]
    ) -> (visible: [String], truncated: Int) {
        let all = RemoteIPParser.unique(connected + banned)
        let visible = Array(all.prefix(maxGeolocatedIPs))
        return (visible, max(0, all.count - visible.count))
    }

    private func makePoints(
        connected: [String],
        banned: [String],
        locations: [String: IPGeolocation]
    ) -> [RemoteIPMapPoint] {
        let connectedOnly = connected.filter { !banned.contains($0) }
        let connectedPoints = connectedOnly.compactMap { ip -> RemoteIPMapPoint? in
            guard let location = locations[ip] else { return nil }
            return RemoteIPMapPoint(ip: ip, kind: .connected, location: location)
        }
        let bannedPoints = banned.compactMap { ip -> RemoteIPMapPoint? in
            guard let location = locations[ip] else { return nil }
            return RemoteIPMapPoint(ip: ip, kind: .banned, location: location)
        }
        return connectedPoints + bannedPoints
    }
}

private struct RemoteIPMapSnapshot {
    let connectedCount: Int
    let bannedCount: Int
    let truncatedCount: Int
    let points: [RemoteIPMapPoint]
    let updatedAt: Date?

    static let empty = RemoteIPMapSnapshot(
        connectedCount: 0,
        bannedCount: 0,
        truncatedCount: 0,
        points: [],
        updatedAt: nil
    )
}

private enum RemoteIPMapPointKind {
    case connected
    case banned

    var color: Color {
        switch self {
        case .connected: return .green
        case .banned:    return .red
        }
    }

    var title: String {
        switch self {
        case .connected: return "Connected"
        case .banned:    return "Banned"
        }
    }
}

private struct RemoteIPMapPoint: Identifiable {
    let ip: String
    let kind: RemoteIPMapPointKind
    let location: IPGeolocation

    var id: String { "\(kind.title):\(ip)" }

    var helpText: String {
        let place = [location.city, location.country]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", ")
        return place.isEmpty ? "\(kind.title): \(ip)" : "\(kind.title): \(ip) - \(place)"
    }
}

private struct WorldMapCanvas: View {
    let points: [RemoteIPMapPoint]

    @State private var region = Self.worldRegion

    private static let worldRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 18, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 145, longitudeDelta: 360)
    )

    private var regionKey: String {
        points
            .map { point in
                "\(point.id):\(point.location.coordinate.latitude):\(point.location.coordinate.longitude)"
            }
            .joined(separator: "|")
    }

    var body: some View {
        Map(coordinateRegion: $region, annotationItems: points) { point in
            MapAnnotation(coordinate: point.location.coordinate.mapCoordinate) {
                Circle()
                    .fill(point.kind.color)
                    .frame(width: point.kind == .banned ? 10 : 9, height: point.kind == .banned ? 10 : 9)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 1.25)
                    )
                    .shadow(color: point.kind.color.opacity(0.65), radius: 5)
                    .help(point.helpText)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .onAppear {
            fitRegionToPoints()
        }
        .onChange(of: regionKey) { _ in
            fitRegionToPoints()
        }
    }

    private func fitRegionToPoints() {
        guard !points.isEmpty else {
            region = Self.worldRegion
            return
        }

        let latitudes = points.map(\.location.coordinate.latitude)
        let longitudes = points.map(\.location.coordinate.longitude)
        guard let minLatitude = latitudes.min(),
              let maxLatitude = latitudes.max()
        else {
            region = Self.worldRegion
            return
        }

        let longitudeFit = Self.fittedLongitudeCenterAndSpan(longitudes)
        let latitudeDelta = Self.paddedDelta(maxLatitude - minLatitude, minimum: 18, maximum: 145)
        let longitudeDelta = Self.paddedDelta(longitudeFit.span, minimum: 28, maximum: 360)
        let latitudeCenter = max(-72, min(72, (minLatitude + maxLatitude) / 2))

        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: latitudeCenter,
                longitude: Self.normalizedLongitude(longitudeFit.center)
            ),
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        )
    }

    private static func paddedDelta(_ delta: Double, minimum: Double, maximum: Double) -> Double {
        let padded = delta <= 0 ? minimum : delta * 1.4 + minimum * 0.35
        return min(maximum, max(minimum, padded))
    }

    private static func fittedLongitudeCenterAndSpan(_ longitudes: [Double]) -> (center: Double, span: Double) {
        guard !longitudes.isEmpty else { return (0, 360) }
        let sorted = longitudes
            .map { normalized360($0) }
            .sorted()
        guard sorted.count > 1 else {
            return (sorted[0], 0)
        }

        var largestGap = -1.0
        var gapAfterIndex = 0
        for index in sorted.indices {
            let current = sorted[index]
            let next = index == sorted.index(before: sorted.endIndex)
                ? sorted[0] + 360
                : sorted[sorted.index(after: index)]
            let gap = next - current
            if gap > largestGap {
                largestGap = gap
                gapAfterIndex = index
            }
        }

        let startIndex = sorted.index(after: gapAfterIndex) == sorted.endIndex
            ? sorted.startIndex
            : sorted.index(after: gapAfterIndex)
        let start = sorted[startIndex]
        let end = sorted[gapAfterIndex] < start
            ? sorted[gapAfterIndex] + 360
            : sorted[gapAfterIndex]
        return (center: start + (end - start) / 2, span: end - start)
    }

    private static func normalized360(_ longitude: Double) -> Double {
        let value = longitude.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        let value = (longitude + 180).truncatingRemainder(dividingBy: 360)
        return (value < 0 ? value + 360 : value) - 180
    }
}

private struct GeoCoordinate {
    let longitude: Double
    let latitude: Double

    var mapCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct IPGeolocation {
    let coordinate: GeoCoordinate
    let city: String?
    let country: String?
}

private actor IPGeolocationService {
    static let shared = IPGeolocationService()

    private var cache: [String: IPGeolocation] = [:]
    private var failed = Set<String>()

    func lookup(_ ips: [String]) async -> [String: IPGeolocation] {
        let unique = RemoteIPParser.unique(ips)
        var result: [String: IPGeolocation] = [:]

        for ip in unique {
            if let cached = cache[ip] {
                result[ip] = cached
                continue
            }
            if failed.contains(ip) {
                continue
            }
            guard !Task.isCancelled else { break }
            if let location = await fetch(ip) {
                cache[ip] = location
                result[ip] = location
            } else {
                failed.insert(ip)
            }
        }

        return result
    }

    private func fetch(_ ip: String) async -> IPGeolocation? {
        guard let encodedIP = ip.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://ipwho.is/\(encodedIP)?fields=success,message,ip,latitude,longitude,city,country,country_code")
        else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(IPWhoIsResponse.self, from: data)
            guard decoded.success,
                  let latitude = decoded.latitude,
                  let longitude = decoded.longitude,
                  (-90...90).contains(latitude),
                  (-180...180).contains(longitude)
            else { return nil }
            return IPGeolocation(
                coordinate: GeoCoordinate(longitude: longitude, latitude: latitude),
                city: decoded.city,
                country: decoded.country
            )
        } catch {
            return nil
        }
    }
}

private struct IPWhoIsResponse: Decodable {
    let success: Bool
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let country: String?
}

private enum RemoteIPParser {
    static func parse(_ output: String) -> (connected: [String], banned: [String]) {
        var connected: [String] = []
        var banned: [String] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let ip = extractIPAddress(from: String(parts[1])),
                  isPublicIPAddress(ip)
            else { continue }

            switch parts[0] {
            case "CONNECTED":
                appendUnique(ip, to: &connected)
            case "BANNED":
                appendUnique(ip, to: &banned)
            default:
                continue
            }
        }

        return (connected, banned)
    }

    static func unique(_ values: [String]) -> [String] {
        values.reduce(into: [String]()) { result, value in
            if !result.contains(value) {
                result.append(value)
            }
        }
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        if !values.contains(value) {
            values.append(value)
        }
    }

    private static func extractIPAddress(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ipv4 = extractIPv4(from: trimmed) {
            return ipv4
        }

        if let start = trimmed.firstIndex(of: "["),
           let end = trimmed[start...].firstIndex(of: "]") {
            let candidate = String(trimmed[trimmed.index(after: start)..<end])
            return looksLikeIPv6(candidate) ? normalizeIPv6(candidate) : nil
        }

        let token = trimmed
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .first
            .map(String.init) ?? trimmed
        let withoutCIDR = token.split(separator: "/", maxSplits: 1).first.map(String.init) ?? token
        let withoutZone = withoutCIDR.split(separator: "%", maxSplits: 1).first.map(String.init) ?? withoutCIDR
        let candidate = withoutZone.trimmingCharacters(in: CharacterSet(charactersIn: "[]()<>;"))
        return looksLikeIPv6(candidate) ? normalizeIPv6(candidate) : nil
    }

    private static func extractIPv4(from value: String) -> String? {
        let pattern = #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let swiftRange = Range(match.range, in: value)
        else { return nil }
        let candidate = String(value[swiftRange])
        let octets = candidate.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets.allSatisfy { (0...255).contains($0) } ? candidate : nil
    }

    private static func looksLikeIPv6(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:")
        return value.contains(":")
            && value.rangeOfCharacter(from: allowed.inverted) == nil
            && (value.contains("::") || value.split(separator: ":").count >= 3)
    }

    private static func normalizeIPv6(_ value: String) -> String {
        value.lowercased()
    }

    private static func isPublicIPAddress(_ ip: String) -> Bool {
        if ip.contains(":") {
            return isPublicIPv6(ip)
        }
        return isPublicIPv4(ip)
    }

    private static func isPublicIPv4(_ ip: String) -> Bool {
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        let first = octets[0]
        let second = octets[1]
        let third = octets[2]

        if first == 0 || first == 10 || first == 127 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 168 { return false }
        if first == 192 && second == 0 && third == 2 { return false }
        if first == 198 && (second == 18 || second == 19) { return false }
        if first == 198 && second == 51 && third == 100 { return false }
        if first == 203 && second == 0 && third == 113 { return false }
        if first >= 224 { return false }
        return true
    }

    private static func isPublicIPv6(_ ip: String) -> Bool {
        let lower = ip.lowercased()
        if lower == "::" || lower == "::1" { return false }
        if lower.hasPrefix("fe80:") { return false }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return false }
        if lower.hasPrefix("ff") { return false }
        if lower.hasPrefix("2001:db8") { return false }
        return true
    }
}

import Charts
import SwiftUI
import OSLog

/// Polls `rshellGetSystemStats` every few seconds for the active
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

    @State private var stats: FfiSystemStats?
    @State private var error: String?
    /// Set when the host's OS isn't supported. Renders a stable
    /// placeholder so we don't spam the user with parse errors on
    /// every poll. Reset on connection change.
    @State private var unsupportedOs: String?
    /// Sliding window of recent samples for the CPU / memory trend
    /// charts. Capped at `maxHistory` — older samples are dropped at
    /// each append. Reset on `connectionId` change so a switch between
    /// hosts doesn't render misleading lines that span both.
    @State private var history: [StatSample] = []

    private let logger = Logger(subsystem: "com.r-shell", category: "monitor")
    private static let pollInterval: UInt64 = 3_000_000_000  // 3 s
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
        .task(id: connectionId) {
            await pollLoop()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(.secondary)
            Text(connectionLabel)
                .font(.headline)
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

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metricBlock(
                    title: "CPU",
                    icon: "cpu",
                    progress: stats.cpuPercent / 100,
                    rightLabel: String(format: "%.1f%%", stats.cpuPercent),
                    series: \.cpuPercent
                )

                metricBlock(
                    title: "Memory",
                    icon: "memorychip",
                    progress: memoryPercent / 100,
                    rightLabel: "\(formatBytes(stats.memoryUsed)) / \(formatBytes(stats.memoryTotal))",
                    series: \.memoryPercent
                )

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
            }
            .padding(16)
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
        // Drop the previous connection's history and any sticky
        // error / unsupported flag. The `.task(id:)` semantics give us
        // a fresh task per connectionId, so this runs exactly when the
        // user switches hosts.
        history.removeAll()
        unsupportedOs = nil
        error = nil

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
        let result: Result<FfiSystemStats, Error> = await Task.detached {
            do {
                return .success(try rshellGetSystemStats(connectionId: connectionId))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let s):
            stats = s
            error = nil
            unsupportedOs = nil
            recordSample(s)
        case .failure(let err as MonitorError):
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
        case .failure(let err):
            error = err.localizedDescription
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

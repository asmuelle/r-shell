import Charts
import Foundation
import MapKit
import SwiftUI
import OSLog

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
    var sshPort: UInt16? = nil
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
        return HStack(spacing: 4) {
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

                if let connectionId {
                    ConnectionWorldMapView(connectionId: connectionId)
                }
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

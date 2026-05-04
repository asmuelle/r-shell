import SwiftUI
import UIKit

struct MobileDevOpsPanelsView: View {
    let connectionId: String

    @State private var mode = Mode.logs
    @State private var logs = ""
    @State private var services: [MobileSystemdUnit] = []
    @State private var search = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?

    @State private var logUnitFilter = ""
    @State private var logServiceNames: [String] = []
    @State private var logTimeFilter = MobileLogTimeFilter.fifteenMinutes
    @State private var logSeverityFilter = MobileLogSeverity.warning
    @State private var logFollowEnabled = false
    @State private var isFollowing = false

    @State private var serviceActionResult: MobileServiceActionResult?
    @State private var serviceActionInProgress: String?
    @State private var serviceStatusDetail: MobileServiceStatusDetail?

    private enum Mode: String, CaseIterable, Identifiable {
        case logs = "Logs"
        case services = "Services"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            if mode == .services {
                serviceSummary
            }

            TextField("Filter", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            switch mode {
            case .logs:
                logsPane
            case .services:
                servicesPane
            }
        }
        .task(id: connectionId) {
            await refresh()
        }
        .onChange(of: mode) {
            search = ""
            Task { await refresh() }
        }
        .sheet(item: $serviceActionResult) { result in
            MobileServiceActionResultSheet(result: result)
        }
        .sheet(item: $serviceStatusDetail) { detail in
            MobileServiceStatusDetailSheet(detail: detail)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("DevOps", systemImage: "wrench.and.screwdriver")
                    .font(.headline)

                Spacer()

                if let lastUpdated {
                    Text(lastUpdated, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

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
                .accessibilityLabel("Refresh DevOps panels")
            }

            Picker("Panel", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
        }
    }

    private var logsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            logFilterBar

            HStack {
                Text(journalctlPreviewLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    UIPasteboard.general.string = filteredLogText
                }
                .disabled(filteredLogText.isEmpty)
            }

            ScrollView {
                Text(filteredLogText.isEmpty ? "No log lines matched." : filteredLogText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 220, maxHeight: 320)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var journalctlPreviewLabel: String {
        var parts: [String] = ["Host Logs"]
        if !logUnitFilter.isEmpty { parts.append("(\(logUnitFilter))") }
        if logTimeFilter != .fifteenMinutes || logSeverityFilter != .warning {
            parts.append("[\(logTimeFilter.rawValue)/\(logSeverityFilter.rawValue)]")
        }
        return parts.joined(separator: " ")
    }

    private var logFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !logServiceNames.isEmpty {
                    Picker("Unit", selection: $logUnitFilter) {
                        Text("All units").tag("")
                        ForEach(logServiceNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                }

                Picker("Time", selection: $logTimeFilter) {
                    ForEach(MobileLogTimeFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 110)

                Picker("Level", selection: $logSeverityFilter) {
                    ForEach(MobileLogSeverity.allCases) { severity in
                        Text(severity.rawValue).tag(severity)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 100)

                Spacer()

                Button {
                    logFollowEnabled.toggle()
                    if logFollowEnabled {
                        Task { await startFollow() }
                    } else {
                        isFollowing = false
                    }
                } label: {
                    Image(systemName: logFollowEnabled ? "stop.fill" : "play.fill")
                        .foregroundStyle(logFollowEnabled ? .red : .green)
                }
                .buttonStyle(.bordered)
                .disabled(isFollowing)
                .accessibilityLabel(logFollowEnabled ? "Stop follow" : "Start follow")

                if isFollowing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .onChange(of: logUnitFilter) { Task { await refreshLogsForFilterChange() } }
        .onChange(of: logTimeFilter) { Task { await refreshLogsForFilterChange() } }
        .onChange(of: logSeverityFilter) { Task { await refreshLogsForFilterChange() } }
    }

    private var servicesPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if filteredServices.isEmpty {
                Text("No services matched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(filteredServices.prefix(20)) { service in
                    serviceRow(service)
                }
            }
        }
    }

    private func serviceRow(_ service: MobileSystemdUnit) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(serviceColor(service))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(service.description.isEmpty ? service.statusText : service.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if serviceActionInProgress == service.name {
                ProgressView()
                    .controlSize(.small)
            }

            Text(service.statusText)
                .font(.caption2.monospaced())
                .foregroundStyle(serviceColor(service))
                .lineLimit(1)
        }
        .padding(.vertical, 5)
        .contextMenu {
            if service.active == "active" {
                Button { Task { await performServiceAction(.stop, on: service) } } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                Button { Task { await performServiceAction(.restart, on: service) } } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
            } else {
                Button { Task { await performServiceAction(.start, on: service) } } label: {
                    Label("Start", systemImage: "play.circle")
                }
            }

            if ["enabled", "enabled-runtime"].contains(service.sub) || service.sub.hasPrefix("static") {
                Button { Task { await performServiceAction(.disable, on: service) } } label: {
                    Label("Disable", systemImage: "togglepower")
                }
            } else {
                Button { Task { await performServiceAction(.enable, on: service) } } label: {
                    Label("Enable", systemImage: "togglepower")
                }
            }

            Button { Task { await performServiceAction(.mask, on: service) } } label: {
                Label("Mask", systemImage: "eye.slash")
            }

            Divider()

            Button { Task { await showServiceStatus(service) } } label: {
                Label("Status", systemImage: "info.circle")
            }
            Button { Task { await showServiceLogs(service) } } label: {
                Label("View Logs", systemImage: "doc.text.magnifyingglass")
            }
        }
        .swipeActions(edge: .trailing) {
            if service.active == "active" {
                Button("Stop", systemImage: "stop.circle") {
                    Task { await performServiceAction(.stop, on: service) }
                }
                .tint(.red)
                Button("Restart", systemImage: "arrow.clockwise") {
                    Task { await performServiceAction(.restart, on: service) }
                }
                .tint(.orange)
            } else if service.active == "failed" {
                Button("Start", systemImage: "play.circle") {
                    Task { await performServiceAction(.start, on: service) }
                }
                .tint(.green)
                Button("Restart", systemImage: "arrow.clockwise") {
                    Task { await performServiceAction(.restart, on: service) }
                }
                .tint(.orange)
            } else {
                Button("Start", systemImage: "play.circle") {
                    Task { await performServiceAction(.start, on: service) }
                }
                .tint(.green)
            }
        }
    }

    private var serviceSummary: some View {
        HStack(spacing: 10) {
            serviceSummaryCell("Total", "\(services.count)", .secondary)
            serviceSummaryCell("Active", "\(services.filter { $0.active == "active" }.count)", .green)
            serviceSummaryCell("Failed", "\(services.filter { $0.active == "failed" }.count)", .red)
            serviceSummaryCell("Enabled", "\(services.filter { ["enabled", "enabled-runtime"].contains($0.sub) || $0.sub.hasPrefix("static") }.count)", .blue)
        }
    }

    private func serviceSummaryCell(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var filteredLogText: String {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = logs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return source }
        return source
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.lowercased().contains(needle) }
            .joined(separator: "\n")
    }

    private var filteredServices: [MobileSystemdUnit] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = services.sorted { lhs, rhs in
            let lhsRank = serviceRank(lhs)
            let rhsRank = serviceRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        guard !needle.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(needle)
                || $0.description.lowercased().contains(needle)
                || $0.statusText.lowercased().contains(needle)
        }
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil

        do {
            switch mode {
            case .logs:
                try await refreshLogs()
            case .services:
                services = try await loadServices()
            }
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    @MainActor
    private func refreshLogs() async throws {
        logs = try await loadLogs()

        if !logServiceNames.isEmpty { return }

        do {
            let svcs = try await loadServices()
            logServiceNames = svcs.map(\.name).sorted()
        } catch {
            _ = error
        }
    }

    @MainActor
    private func refreshLogsForFilterChange() async {
        do {
            errorMessage = nil
            try await refreshLogs()
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadLogs() async throws -> String {
        var script = ""
        let useJournalctl = "command -v journalctl >/dev/null 2>&1"

        script += "if \(useJournalctl); then\n"

        if logFollowEnabled {
            script += "  journalctl"
        } else {
            script += "  out=$(journalctl"
        }

        if !logUnitFilter.isEmpty {
            script += " -u \(shellQuote(logUnitFilter))"
        }

        script += " -p \(logSeverityFilter.journaldLevel)"

        script += " \(logTimeFilter.journalctlSince)"

        if logFollowEnabled {
            script += " -o short-iso -n 80 -f 2>&1 &\n"
            script += "  sleep 6\n"
            script += "  kill %1 2>/dev/null\n"
            script += "  wait 2>/dev/null\n"
        } else {
            script += " -n 200 --no-pager -o short-iso 2>&1)\n"
            script += "  rc=$?\n"
            script += "  if [ \"$rc\" -ne 0 ] && command -v sudo >/dev/null 2>&1; then\n"
            script += "    sudo -n journalctl"

            if !logUnitFilter.isEmpty {
                script += " -u \(shellQuote(logUnitFilter))"
            }
            script += " -p \(logSeverityFilter.journaldLevel)"
            script += " \(logTimeFilter.journalctlSince)"
            script += " -n 200 --no-pager -o short-iso 2>&1\n"
            script += "  else\n"
            script += "    printf '%s\\n' \"$out\"\n"
            script += "  fi\n"
        }

        script += "elif [ -r /var/log/syslog ]; then\n"
        script += "  tail -n 200 /var/log/syslog\n"
        script += "elif [ -r /var/log/system.log ]; then\n"
        script += "  tail -n 200 /var/log/system.log\n"
        script += "else\n"
        script += "  echo 'No readable journalctl, /var/log/syslog, or /var/log/system.log source found.'\n"
        script += "fi"

        return try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )
    }

    private func startFollow() async {
        isFollowing = true
        defer { isFollowing = false }

        do {
            logs = try await loadLogs()
            lastUpdated = Date()

            try await Task.sleep(nanoseconds: 6_000_000_000)
            if logFollowEnabled {
                logs = try await loadLogs()
                lastUpdated = Date()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        if logFollowEnabled && !isFollowing {
            Task { await startFollow() }
        }
    }

    private func loadServices() async throws -> [MobileSystemdUnit] {
        let script = """
        command -v systemctl >/dev/null 2>&1 || { echo __MIDNIGHT_SSH_SYSTEMD_UNAVAILABLE__; exit 0; }
        export LC_ALL=C
        systemctl list-units --type=service --all --no-legend --no-pager 2>&1
        """
        let output = try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )
        if output.contains("__MIDNIGHT_SSH_SYSTEMD_UNAVAILABLE__") {
            throw MobileDevOpsError.unavailable("systemctl is not available on this host.")
        }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { MobileSystemdUnit.parse(String($0)) }
    }

    private func showServiceStatus(_ service: MobileSystemdUnit) async {
        do {
            let script = """
            systemctl --no-pager --full status \(shellQuote(service.name)) 2>&1 | head -120
            """
            let output = try await MobileMonitorBridge.shared.executeCommand(
                connectionId: connectionId,
                command: script
            )
            serviceStatusDetail = MobileServiceStatusDetail(serviceName: service.name, output: output)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func showServiceLogs(_ service: MobileSystemdUnit) async {
        do {
            let script = """
            if command -v journalctl >/dev/null 2>&1; then
              journalctl -u \(shellQuote(service.name)) --no-pager -n 200 -o short-iso 2>&1
            else
              echo 'journalctl not available on this host.'
            fi
            """
            let output = try await MobileMonitorBridge.shared.executeCommand(
                connectionId: connectionId,
                command: script
            )
            serviceStatusDetail = MobileServiceStatusDetail(serviceName: "\(service.name) logs", output: output)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performServiceAction(_ action: MobileServiceAction, on service: MobileSystemdUnit) async {
        serviceActionInProgress = service.name
        defer { serviceActionInProgress = nil }

        let cmd: String
        let label: String

        switch action {
        case .start:
            cmd = "sudo -n systemctl start \(shellQuote(service.name)) && systemctl --no-pager --full status \(shellQuote(service.name)) 2>&1 | head -40"
            label = "Start \(service.name)"
        case .stop:
            cmd = "sudo -n systemctl stop \(shellQuote(service.name)) && systemctl --no-pager --full status \(shellQuote(service.name)) 2>&1 | head -40"
            label = "Stop \(service.name)"
        case .restart:
            cmd = "sudo -n systemctl restart \(shellQuote(service.name)) && systemctl --no-pager --full status \(shellQuote(service.name)) 2>&1 | head -40"
            label = "Restart \(service.name)"
        case .enable:
            cmd = "sudo -n systemctl enable \(shellQuote(service.name)) 2>&1"
            label = "Enable \(service.name)"
        case .disable:
            cmd = "sudo -n systemctl disable \(shellQuote(service.name)) 2>&1"
            label = "Disable \(service.name)"
        case .mask:
            cmd = "sudo -n systemctl mask \(shellQuote(service.name)) 2>&1"
            label = "Mask \(service.name)"
        }

        do {
            let output = try await MobileMonitorBridge.shared.executeCommand(
                connectionId: connectionId,
                command: cmd
            )
            serviceActionResult = MobileServiceActionResult(label: label, output: output)

            MobileActivityLogStore.shared.record(
                title: "Service \(action.rawValue)",
                detail: "\(service.name) on \(connectionId.prefix(8))",
                connectionId: connectionId,
                systemImage: "arrow.triangle.2.circlepath",
                severity: .info
            )

            services = try await loadServices()
        } catch {
            errorMessage = error.localizedDescription
            serviceActionResult = MobileServiceActionResult(label: label, output: error.localizedDescription)
        }
    }

    private func serviceColor(_ service: MobileSystemdUnit) -> Color {
        switch service.active {
        case "active":
            return .green
        case "failed":
            return .red
        case "activating", "deactivating", "reloading":
            return .orange
        default:
            return .secondary
        }
    }

    private func serviceRank(_ service: MobileSystemdUnit) -> Int {
        switch service.active {
        case "failed":
            return 0
        case "activating", "deactivating", "reloading":
            return 1
        case "active":
            return 2
        default:
            return 3
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

private enum MobileLogTimeFilter: String, CaseIterable, Identifiable {
    case fifteenMinutes = "15m"
    case oneHour = "1h"
    case sixHours = "6h"
    case twentyFourHours = "24h"
    case sinceBoot = "boot"

    var id: String { rawValue }

    var journalctlSince: String {
        switch self {
        case .fifteenMinutes: return "--since '15 min ago'"
        case .oneHour: return "--since '1 hour ago'"
        case .sixHours: return "--since '6 hours ago'"
        case .twentyFourHours: return "--since '24 hours ago'"
        case .sinceBoot: return "-b"
        }
    }
}

private enum MobileLogSeverity: String, CaseIterable, Identifiable {
    case emerg = "emerg"
    case alert = "alert"
    case crit = "crit"
    case err = "err"
    case warning = "warn"
    case notice = "notice"
    case info = "info"
    case debug = "debug"

    var id: String { rawValue }

    var journaldLevel: String {
        switch self {
        case .emerg: return "emerg"
        case .alert: return "alert"
        case .crit: return "crit"
        case .err: return "err"
        case .warning: return "warning"
        case .notice: return "notice"
        case .info: return "info"
        case .debug: return "debug"
        }
    }
}

private enum MobileServiceAction: String {
    case start
    case stop
    case restart
    case enable
    case disable
    case mask
}

private struct MobileServiceActionResult: Identifiable {
    let id = UUID()
    let label: String
    let output: String
}

private struct MobileServiceStatusDetail: Identifiable {
    let id = UUID()
    let serviceName: String
    let output: String
}

private struct MobileServiceActionResultSheet: View {
    let result: MobileServiceActionResult

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(result.output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            .padding()
            .navigationTitle(result.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct MobileServiceStatusDetailSheet: View {
    let detail: MobileServiceStatusDetail

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(detail.output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            .padding()
            .navigationTitle(detail.serviceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        UIPasteboard.general.string = detail.output
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct MobileSystemdUnit: Identifiable, Hashable {
    let name: String
    let load: String
    let active: String
    let sub: String
    let description: String

    var id: String { name }
    var statusText: String { "\(active)/\(sub)" }

    static func parse(_ line: String) -> MobileSystemdUnit? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var fields = trimmed.split(maxSplits: 4, whereSeparator: \.isWhitespace).map(String.init)
        if fields.first == "\u{25CF}" {
            fields.removeFirst()
        }
        guard fields.count >= 4, fields[0].hasSuffix(".service") else { return nil }

        return MobileSystemdUnit(
            name: fields[0],
            load: fields[1],
            active: fields[2],
            sub: fields[3],
            description: fields.count >= 5 ? fields[4] : ""
        )
    }
}

private enum MobileDevOpsError: Error, LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

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
        .onChange(of: mode) { _ in
            search = ""
            Task { await refresh() }
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
            HStack {
                Text("Recent Host Logs")
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
                ForEach(filteredServices.prefix(12)) { service in
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

                        Text(service.statusText)
                            .font(.caption2.monospaced())
                            .foregroundStyle(serviceColor(service))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private var serviceSummary: some View {
        HStack(spacing: 10) {
            serviceSummaryCell("Total", "\(services.count)", .secondary)
            serviceSummaryCell("Active", "\(services.filter { $0.active == "active" }.count)", .green)
            serviceSummaryCell("Failed", "\(services.filter { $0.active == "failed" }.count)", .red)
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
                logs = try await loadLogs()
            case .services:
                services = try await loadServices()
            }
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func loadLogs() async throws -> String {
        let script = """
        if command -v journalctl >/dev/null 2>&1; then
          out=$(journalctl -p warning -n 140 --no-pager -o short-iso 2>&1)
          rc=$?
          if [ "$rc" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
            sudo -n journalctl -p warning -n 140 --no-pager -o short-iso 2>&1
          else
            printf '%s\\n' "$out"
          fi
        elif [ -r /var/log/syslog ]; then
          tail -n 140 /var/log/syslog
        elif [ -r /var/log/system.log ]; then
          tail -n 140 /var/log/system.log
        else
          echo 'No readable journalctl, /var/log/syslog, or /var/log/system.log source found.'
        fi
        """
        return try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )
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

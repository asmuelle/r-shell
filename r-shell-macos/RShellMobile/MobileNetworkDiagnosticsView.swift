import SwiftUI

struct MobileNetworkDiagnosticsView: View {
    let connectionId: String

    @State private var mode = NetworkMode.ports
    @State private var listeningPorts: [MobileListeningPort] = []
    @State private var interfaceStats: [MobileNetworkInterface] = []
    @State private var dnsInfo: String = ""
    @State private var arpTable: [MobileArpEntry] = []
    @State private var connectionSummary: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?

    private enum NetworkMode: String, CaseIterable, Identifiable {
        case ports = "Listening"
        case interfaces = "Interfaces"
        case dns = "DNS"
        case arp = "ARP"

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

            switch mode {
            case .ports:
                listeningPortsPane
            case .interfaces:
                interfacesPane
            case .dns:
                dnsPane
            case .arp:
                arpPane
            }
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: connectionId) {
            await refresh()
        }
        .onChange(of: mode) { _ in
            Task { await refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Network", systemImage: "network")
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
            }

            Picker("View", selection: $mode) {
                ForEach(NetworkMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)
        }
    }

    private var listeningPortsPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !connectionSummary.isEmpty {
                Text(connectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }

            if listeningPorts.isEmpty {
                emptyState("No listening ports data.")
            } else {
                ForEach(listeningPorts) { port in
                    HStack(spacing: 8) {
                        Text(port.boundAddress)
                            .font(.caption2.monospaced())
                            .foregroundStyle(port.isPublic ? .orange : .green)
                            .lineLimit(1)
                            .frame(width: 80, alignment: .leading)

                        Text(port.process)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var interfacesPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            if interfaceStats.isEmpty {
                emptyState("No interface data.")
            } else {
                ForEach(interfaceStats) { iface in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle()
                                .fill(iface.isUp ? .green : .secondary)
                                .frame(width: 6, height: 6)
                            Text(iface.name)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(iface.macAddress)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if !iface.ipAddresses.isEmpty {
                            Text(iface.ipAddresses.joined(separator: " "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.blue)
                        }
                        HStack {
                            Text("RX: \(iface.rxFormatted)")
                                .font(.caption2)
                            Text("TX: \(iface.txFormatted)")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var dnsPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dnsInfo.isEmpty {
                emptyState("No DNS info.")
            } else {
                ScrollView {
                    Text(dnsInfo)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 160)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var arpPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            if arpTable.isEmpty {
                emptyState("No ARP entries.")
            } else {
                ForEach(arpTable) { entry in
                    HStack(spacing: 8) {
                        Text(entry.ip)
                            .font(.caption2.monospaced())
                            .frame(width: 90, alignment: .leading)
                        Text(entry.mac)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.iface)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            switch mode {
            case .ports:
                async let ports = loadListeningPorts()
                async let summary = loadConnectionSummary()
                (listeningPorts, connectionSummary) = (try await ports, try await summary)
            case .interfaces:
                interfaceStats = try await loadInterfaceStats()
            case .dns:
                dnsInfo = try await loadDNSInfo()
            case .arp:
                arpTable = try await loadArpTable()
            }
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadListeningPorts() async throws -> [MobileListeningPort] {
        let script = """
        ss -tlnp 2>&1 || netstat -tlnp 2>&1 || echo "__MIDNIGHT_NO_UTIL__"
        """
        let output = try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )
        guard !output.contains("__MIDNIGHT_NO_UTIL__") else { return [] }

        return output
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line in
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.contains("LISTEN") else { return nil }
                let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 5 else { return nil }
                let local = parts[4]
                let isPublic = local.contains("0.0.0.0") || local.contains("::") || local.contains("*")
                let process = parts.dropFirst(5).joined(separator: " ")
                return MobileListeningPort(
                    boundAddress: local,
                    process: process,
                    isPublic: isPublic
                )
            }
    }

    private func loadConnectionSummary() async throws -> String {
        let script = "ss -s 2>&1 || netstat -s 2>&1 | head -10 || echo '-'"
        return try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )
    }

    private func loadInterfaceStats() async throws -> [MobileNetworkInterface] {
        let script = """
        ip -o addr show 2>/dev/null || ifconfig 2>/dev/null || echo "__MIDNIGHT_NO_UTIL__"
        echo "===MAC==="
        ip -o link show 2>/dev/null || ifconfig 2>/dev/null || true
        """
        return try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )
            .split(separator: "===MAC===")
            .first
            .map { String($0) }
            .map { parseInterfaces($0) } ?? []
    }

    private func parseInterfaces(_ output: String) -> [MobileNetworkInterface] {
        var interfaces: [String: (name: String, ips: [String], up: Bool)] = [:]

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { continue }

            var name = fields[0]
            if name.hasSuffix(":") {
                name = String(name.dropLast())
            }

            let up = trimmed.contains("UP") || trimmed.contains("<UP") || trimmed.contains("state UP")

            if fields.count >= 2, fields[1].hasPrefix("inet") {
                var existing = interfaces[name] ?? (name: name, ips: [], up: up)
                existing.ips.append(fields[1])
                interfaces[name] = existing
            } else if interfaces[name] == nil {
                interfaces[name] = (name: name, ips: [], up: up)
            }
        }

        return interfaces.values.map {
            MobileNetworkInterface(
                name: $0.name,
                ipAddresses: $0.ips,
                isUp: $0.up,
                macAddress: "",
                rxFormatted: "",
                txFormatted: ""
            )
        }
    }

    private func loadDNSInfo() async throws -> String {
        let script = """
        echo "=== resolv.conf ==="
        cat /etc/resolv.conf 2>/dev/null || echo "not found"
        echo ""
        echo "=== resolvectl ==="
        resolvectl status 2>/dev/null || systemd-resolve --status 2>/dev/null || echo "not available"
        """
        return try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )
    }

    private func loadArpTable() async throws -> [MobileArpEntry] {
        let script = """
        ip neigh 2>/dev/null || arp -a 2>/dev/null || echo "__MIDNIGHT_NO_UTIL__"
        """
        let output = try await MobileMonitorBridge.shared.executeCommand(
            connectionId: connectionId,
            command: script
        )
        guard !output.contains("__MIDNIGHT_NO_UTIL__") else { return [] }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = String(line).split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 3 else { return nil }
                return MobileArpEntry(
                    ip: parts[0],
                    mac: parts.count >= 5 ? parts[4] : parts[1],
                    iface: parts.count >= 3 ? parts[2] : ""
                )
            }
    }
}

private struct MobileListeningPort: Identifiable {
    let id = UUID()
    let boundAddress: String
    let process: String
    let isPublic: Bool
}

private struct MobileNetworkInterface: Identifiable {
    let id = UUID()
    let name: String
    let ipAddresses: [String]
    let isUp: Bool
    let macAddress: String
    let rxFormatted: String
    let txFormatted: String
}

private struct MobileArpEntry: Identifiable {
    let id = UUID()
    let ip: String
    let mac: String
    let iface: String
}
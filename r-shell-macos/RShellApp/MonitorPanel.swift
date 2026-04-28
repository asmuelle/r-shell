import SwiftUI
import RShellMacOS

/// System monitor panel showing CPU, memory, disk, network, and uptime.
struct MonitorPanel: View {
    let connectionId: String
    @StateObject private var poller = MonitorPollingManager.shared
    @State private var showNetworkDetail = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundColor(.accentColor)
                    Text("System Monitor — \(connectionId)")
                        .font(.headline)
                    Spacer()
                    Text(poller.systemStats.uptime)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // CPU + Memory
                GroupBox("CPU & Memory") {
                    VStack(spacing: 8) {
                        GaugeBar(label: "CPU", value: poller.systemStats.cpuPercent, color: .blue)
                        GaugeBar(label: "Mem", value: poller.systemStats.memoryUsagePercent, color: .green,
                                 detail: "\(poller.systemStats.memoryUsed / 1024 / 1024)G / \(poller.systemStats.memoryTotal / 1024 / 1024)G")
                        GaugeBar(label: "Swap", value: 0, color: .orange)
                    }
                    .padding(4)
                }

                // Network
                GroupBox("Network") {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            StatTile(icon: "arrow.down.circle", label: "RX/s", value: "—", color: .blue)
                            StatTile(icon: "arrow.up.circle", label: "TX/s", value: "—", color: .green)
                            StatTile(icon: "antenna.radiowaves.left.and.right", label: "Latency", value: "—", color: .orange)
                            StatTile(icon: "list.bullet", label: "Interfaces", value: "\(poller.networkStats.interfaces.count)", color: .secondary)
                        }

                        if !poller.networkStats.rxHistory.isEmpty {
                            HStack {
                                Text("Bandwidth (recent)")
                                    .font(.caption)
                                Spacer()
                            }
                            MiniLineChart(data: poller.networkStats.rxHistory.map(Double.init), color: .blue)
                                .frame(height: 40)
                        }
                    }
                    .padding(4)
                }

                // Disk
                GroupBox("Disk") {
                    GaugeBar(label: "Root", value: poller.systemStats.diskUsePercent, color: .purple,
                             detail: "\(poller.systemStats.diskUsed) / \(poller.systemStats.diskTotal)")
                        .padding(4)
                }

                // Load average
                if let load = poller.systemStats.loadAverage {
                    HStack {
                        Text("Load Average:").font(.caption).foregroundColor(.secondary)
                        Text(load).font(.system(size: 11, design: .monospaced))
                        Spacer()
                    }
                }
            }
            .padding()
        }
        .onAppear { poller.startPolling(connectionId: connectionId) }
        .onDisappear { poller.stopPolling(connectionId: connectionId) }
    }
}

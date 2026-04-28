import SwiftUI
import RShellMacOS

/// Process viewer with search, sort, and kill.
struct ProcessPanel: View {
    let connectionId: String
    @StateObject private var poller = MonitorPollingManager.shared
    @State private var searchQuery = ""
    @State private var sortBy: SortField = .cpu
    @State private var sortAsc = false
    @State private var confirmKill: RemoteProcessInfo?

    enum SortField: String, CaseIterable {
        case pid, name, cpu, memory, user
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                TextField("Search processes…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 200)

                Picker("Sort", selection: $sortBy) {
                    ForEach(SortField.allCases, id: \.self) { f in
                        Text(f.rawValue.uppercased()).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Button(action: { sortAsc.toggle() }) {
                    Image(systemName: sortAsc ? "arrow.up" : "arrow.down")
                }
                .buttonStyle(.plain)
                .help("Toggle sort direction")

                Spacer()

                Text("\(filteredProcesses.count) processes")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Process table
            List(filteredProcesses) { proc in
                ProcessRow(process: proc, onKill: { confirmKill = proc })
            }
            .listStyle(.plain)
        }
        .onAppear { poller.startPolling(connectionId: connectionId) }
        .onDisappear { poller.stopPolling(connectionId: connectionId) }
        .alert("Kill Process", isPresented: .constant(confirmKill != nil), presenting: confirmKill) { proc in
            Button("Cancel") { confirmKill = nil }
            Button("Kill \(proc.pid)", role: .destructive) {
                killProcess(proc)
                confirmKill = nil
            }
        } message: { proc in
            Text("Terminate \(proc.name) (PID \(proc.pid))?")
        }
    }

    private var filteredProcesses: [RemoteProcessInfo] {
        var result = poller.processes
        if !searchQuery.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) || "\($0.pid)".contains(searchQuery) }
        }
        result.sort { a, b in
            switch sortBy {
            case .pid: return sortAsc ? a.pid < b.pid : a.pid > b.pid
            case .name: return sortAsc ? a.name < b.name : a.name > b.name
            case .cpu: return sortAsc ? a.cpuPercent < b.cpuPercent : a.cpuPercent > b.cpuPercent
            case .memory: return sortAsc ? a.memoryPercent < b.memoryPercent : a.memoryPercent > b.memoryPercent
            case .user: return sortAsc ? (a.user ?? "") < (b.user ?? "") : (a.user ?? "") > (b.user ?? "")
            }
        }
        return result
    }

    private func killProcess(_ proc: RemoteProcessInfo) {
        // Once FFI: rshell_execute_command(connectionId: connectionId, command: "kill \(proc.pid)")
    }
}

// MARK: - Process row

struct ProcessRow: View {
    let process: RemoteProcessInfo
    var onKill: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text("\(process.pid)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)

            Text(process.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(minWidth: 120, alignment: .leading)

            Text(String(format: "%.1f", process.cpuPercent))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
                .foregroundColor(process.cpuPercent > 50 ? .red : .primary)

            Text(String(format: "%.1f", process.memoryPercent))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 40, alignment: .trailing)

            if let user = process.user {
                Text(user)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .leading)
                    .lineLimit(1)
            }

            if let state = process.state {
                Text(state)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 30)
            }

            Spacer()

            if let onKill {
                Button("Kill", role: .destructive, action: onKill)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 1)
    }
}

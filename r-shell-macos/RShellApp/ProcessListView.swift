import OSLog
import SwiftUI

/// Polls `rshellGetProcesses` for the active connection and renders
/// the result as a sortable Table. Multi-row selection enables
/// bulk-signal flows (Send TERM / Force Kill via context menu).
///
/// Polling cadence: 4 s. The remote `ps` command can spike CPU if
/// run aggressively against a large process tree, and on macOS it
/// reads from kvm — slightly heavier than Linux's `/proc` walk.
/// Slower than the System Monitor (3 s) for the same reason.
///
/// Lives in the bottom panel as a tabbed segment so users opt in to
/// the cost — most sessions don't need a live process view.
struct ProcessListView: View {
    let connectionId: String?
    let connectionLabel: String

    @State private var processes: [FfiProcess] = []
    @State private var sortOrder: [KeyPathComparator<ProcessRow>] = [
        // Default: hottest CPU first, matching what `ps -r` / `ps --sort=-pcpu`
        // emits. Users can change column sort via Table headers.
        .init(\.cpuPercent, order: .reverse)
    ]
    @State private var selection: Set<UInt32> = []
    @State private var error: String?
    @State private var unsupportedOs: String?
    @State private var pendingKill: KillTarget?
    @State private var search: String = ""

    private let logger = Logger(subsystem: "com.r-shell", category: "process-list")
    private static let pollInterval: UInt64 = 4_000_000_000  // 4 s

    /// Identifiable wrapper for SwiftUI Table — wraps an `FfiProcess`
    /// with a stable `pid`-derived id so reconciliation works across
    /// polls without remounting selected rows.
    fileprivate struct ProcessRow: Identifiable, Hashable {
        let pid: UInt32
        let user: String
        let cpuPercent: Double
        let memoryPercent: Double
        let command: String
        let args: String
        var id: UInt32 { pid }

        init(_ p: FfiProcess) {
            self.pid = p.pid
            self.user = p.user
            self.cpuPercent = p.cpuPercent
            self.memoryPercent = p.memoryPercent
            self.command = p.command
            self.args = p.args
        }
    }

    /// Confirmation-dialog target. `pids` is a snapshot of the
    /// selection at click time so removing a row mid-dialog doesn't
    /// silently shrink the kill set.
    fileprivate struct KillTarget: Identifiable {
        let id = UUID()
        let pids: [UInt32]
        let signal: FfiSignal
        var displayName: String {
            pids.count == 1 ? "PID \(pids[0])" : "\(pids.count) processes"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: connectionId) {
            await pollLoop()
        }
        .alert(item: $pendingKill) { target in
            killAlert(target)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.secondary)
            Text(connectionLabel)
                .font(.subheadline.weight(.medium))
            Spacer()
            if !processes.isEmpty {
                Text("\(filteredRows.count) processes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if connectionId == nil {
            placeholder(
                icon: "network.slash",
                message: "Connect to a host to inspect its processes."
            )
        } else if let unsupportedOs {
            placeholder(
                icon: "questionmark.circle",
                message: "Process list isn't available for \(unsupportedOs) hosts."
            )
        } else if let error {
            placeholder(icon: "exclamationmark.triangle", message: error)
        } else if processes.isEmpty {
            ProgressView("Loading processes…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            processTable
        }
    }

    private func placeholder(icon: String, message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Process table

    private var processTable: some View {
        let rows = filteredRows.sorted(using: sortOrder)
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("PID", value: \.pid) { row in
                Text("\(row.pid)").monospacedDigit()
            }
            .width(min: 60, ideal: 70)

            TableColumn("User", value: \.user) { row in
                Text(row.user)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 70, ideal: 100)

            TableColumn("CPU", value: \.cpuPercent) { row in
                Text(String(format: "%.1f%%", row.cpuPercent))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70)

            TableColumn("MEM", value: \.memoryPercent) { row in
                Text(String(format: "%.1f%%", row.memoryPercent))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 70)

            TableColumn("Command", value: \.command) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.command)
                        .font(.callout)
                        .lineLimit(1)
                    if !row.args.isEmpty && row.args != row.command {
                        Text(row.args)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: UInt32.self) { selectedPids in
            contextMenu(for: selectedPids)
        }
    }

    @ViewBuilder
    private func contextMenu(for selectedPids: Set<UInt32>) -> some View {
        // Use the right-click target if there's no current selection,
        // otherwise the Set passed by SwiftUI is the selection at click
        // time and matches the highlighted rows.
        let pids = Array(selectedPids).sorted()
        if !pids.isEmpty {
            Button("Send TERM (\(pids.count))") {
                pendingKill = KillTarget(pids: pids, signal: .term)
            }
            Button("Force Kill (\(pids.count))", role: .destructive) {
                pendingKill = KillTarget(pids: pids, signal: .kill)
            }
            Divider()
            if pids.count == 1, let row = processes.first(where: { $0.pid == pids[0] }) {
                Button("Copy PID") { copyToPasteboard("\(row.pid)") }
                Button("Copy Command") {
                    copyToPasteboard(row.args.isEmpty ? row.command : row.args)
                }
            }
        }
    }

    // MARK: - Kill confirmation

    private func killAlert(_ target: KillTarget) -> Alert {
        let signalLabel = target.signal == .term ? "TERM (graceful)" : "KILL (force)"
        return Alert(
            title: Text("Send \(signalLabel) to \(target.displayName)?"),
            message: Text(killMessage(target)),
            primaryButton: .destructive(Text("Send")) {
                Task { await dispatchKill(target) }
            },
            secondaryButton: .cancel()
        )
    }

    private func killMessage(_ target: KillTarget) -> String {
        guard target.pids.count == 1, let pid = target.pids.first else {
            return "This will signal \(target.pids.count) processes on \(connectionLabel)."
        }
        if let row = processes.first(where: { $0.pid == pid }) {
            return "\(row.command) (\(row.user)) on \(connectionLabel)."
        }
        return "PID \(pid) on \(connectionLabel)."
    }

    private func dispatchKill(_ target: KillTarget) async {
        guard let connectionId else { return }
        for pid in target.pids {
            let result = await Task.detached {
                do {
                    try rshellSignalProcess(
                        connectionId: connectionId,
                        pid: pid,
                        signal: target.signal
                    )
                    return Result<Void, Error>.success(())
                } catch {
                    return Result<Void, Error>.failure(error)
                }
            }.value
            if case .failure(let err) = result {
                logger.error("kill -\(target.signal == .term ? "TERM" : "KILL") \(pid) failed: \(err.localizedDescription, privacy: .public)")
                error = "Failed to signal PID \(pid): \(err.localizedDescription)"
                return
            }
        }
        // Force a refresh on success — wait one cycle so the host
        // has time to actually reap the process before we re-poll.
        await fetchOnce(connectionId: connectionId)
    }

    // MARK: - Polling

    private func pollLoop() async {
        unsupportedOs = nil
        error = nil
        processes = []
        selection.removeAll()

        guard let connectionId else { return }
        while !Task.isCancelled {
            await fetchOnce(connectionId: connectionId)
            if unsupportedOs != nil { return }
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    private func fetchOnce(connectionId: String) async {
        let result: Result<[FfiProcess], Error> = await Task.detached {
            do {
                return .success(try rshellGetProcesses(connectionId: connectionId))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let rows):
            processes = rows
            error = nil
            unsupportedOs = nil
            // Drop selections that point at processes that have
            // exited since the last poll — otherwise the context
            // menu would offer to kill PIDs that no longer exist.
            let alivePids = Set(rows.map { $0.pid })
            selection = selection.intersection(alivePids)
        case .failure(let err as MonitorError):
            switch err {
            case .Unsupported(let os):
                unsupportedOs = os
                error = nil
            case .ParseError(let detail):
                error = "Couldn't parse process list: \(detail)"
            case .NotConnected:
                error = "Not connected to this host."
            case .Other(let detail):
                error = detail
            }
        case .failure(let err):
            error = err.localizedDescription
        }
    }

    // MARK: - Helpers

    private var filteredRows: [ProcessRow] {
        let rows = processes.map(ProcessRow.init)
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            row.command.lowercased().contains(needle)
                || row.user.lowercased().contains(needle)
                || row.args.lowercased().contains(needle)
                || "\(row.pid)".contains(needle)
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

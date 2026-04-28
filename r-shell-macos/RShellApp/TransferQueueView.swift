import SwiftUI
import RShellMacOS

/// Transfer queue panel shown in the bottom panel when transfers are active.
/// Lists queued, in-progress, completed, and failed transfers with progress bars.
struct TransferQueueView: View {
    @StateObject private var manager = TransferQueueManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if manager.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("No active transfers")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(manager.items) { item in
                        TransferRow(item: item)
                    }
                    .onDelete { indexSet in
                        for idx in indexSet {
                            guard idx < manager.items.count else { return }
                            manager.cancel(id: manager.items[idx].id)
                        }
                    }
                }
                .listStyle(.plain)

                Divider()

                HStack {
                    Text("\(manager.items.filter { $0.status == .inProgress }.count) active, \(manager.items.filter { $0.status == .queued }.count) queued")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Clear Completed") { manager.clearCompleted() }
                        .font(.caption)
                        .disabled(!manager.items.contains(where: { $0.status == .completed || $0.status == .failed }))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Transfer row

struct TransferRow: View {
    let item: TransferItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.direction == .upload ? "Upload" : "Download")
                    .font(.system(size: 11, weight: .medium))
                Text(item.localPath)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(item.remotePath)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if item.status == .inProgress || item.status == .queued {
                ProgressView(value: item.progress)
                    .frame(width: 80)
            }

            if item.status == .completed || item.status == .failed {
                Text(item.status == .completed ? "Done" : "Failed")
                    .font(.caption)
                    .foregroundColor(item.status == .completed ? .green : .red)
            }

            Text(item.formattedSize)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: String {
        switch item.status {
        case .queued: return "clock"
        case .inProgress: return "arrow.triangle.swap"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .queued: return .orange
        case .inProgress: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
}

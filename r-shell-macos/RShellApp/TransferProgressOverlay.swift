import SwiftUI

/// Floating progress panel that appears during file transfers between panes.
/// Shows each active transfer with source/destination paths, progress bar,
/// and live byte counts. Stays visible until the user dismisses it.
///
/// Positioned as a centered overlay within the dual-pane area, styled like
/// macOS's native copy dialog with translucent material background.
struct TransferProgressOverlay: View {
    @EnvironmentObject var transfers: TransferQueueStore

    @State private var isVisible = false

    private var activeTransfers: [Transfer] {
        transfers.transfers.filter {
            $0.status == .queued || $0.status == .inProgress
        }
    }

    private var finishedTransfers: [Transfer] {
        transfers.transfers.filter {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        }
    }

    /// All transfers the overlay should display — active plus any
    /// finished ones that arrived since the overlay opened.
    private var displayedTransfers: [Transfer] {
        activeTransfers + finishedTransfers
    }

    var body: some View {
        if isVisible {
            panel
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .onChange(of: activeTransfers.isEmpty) { nowEmpty in
                    if !nowEmpty { isVisible = true }
                }
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            // Header with close button
            HStack {
                if !activeTransfers.isEmpty {
                    Text("\(activeTransfers.count) transfer\(activeTransfers.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Transfers complete")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close transfer panel")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            Divider()

            // Transfer rows
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(displayedTransfers) { transfer in
                        TransferRow(
                            transfer: transfer,
                            compact: transfer.status != .inProgress && transfer.status != .queued
                        )
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(12)
        .frame(minWidth: 400, maxWidth: 540)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
        .mask(
            RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.top, 42)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Actions

    private func dismiss() {
        isVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            transfers.clearCompleted()
        }
    }
}

// MARK: - Row

private struct TransferRow: View {
    let transfer: Transfer
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: icon + file name + status
            HStack(spacing: 8) {
                if transfer.status == .inProgress {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .font(.system(size: compact ? 11 : 13, weight: .medium))
                }

                Text(transfer.displayName)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if compact {
                    statusBadge
                } else if transfer.status == .inProgress {
                    Text(transfer.formattedProgress)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Source → Destination
            HStack(spacing: 4) {
                Image(systemName: transfer.kind == .download ? "cloud" : "internaldrive")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(transfer.sourceLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.quaternary)

                Image(systemName: transfer.kind == .download ? "internaldrive" : "cloud")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(transfer.destinationLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Progress bar (only for in-progress)
            if transfer.status == .inProgress || transfer.status == .queued {
                progressSection
            }

            // Separator between rows
            if transfer.status == .inProgress || transfer.status == .queued {
                Divider()
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, compact ? 4 : 6)
    }

    // MARK: - Progress section

    private var progressSection: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(transfer.status == .queued ? Color.secondary : Color.accentColor)
                        .frame(width: transfer.status == .queued ? geo.size.width : max(4, geo.size.width * transfer.progress), height: 4)
                }
            }
            .frame(height: 4)

            HStack {
                if transfer.status == .queued {
                    Text("Queued")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(transfer.formattedBytes)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if transfer.totalBytes > 0 {
                    Text(transfer.formattedTotal)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Helpers

    private var statusIcon: String {
        switch transfer.status {
        case .queued:    return "clock"
        case .inProgress: return "arrow.down.circle"
        case .completed:  return "checkmark.circle.fill"
        case .failed:     return "xmark.circle.fill"
        case .cancelled:  return "stop.circle.fill"
        }
    }

    private var statusColor: Color {
        switch transfer.status {
        case .completed: return .green
        case .failed:    return .red
        case .cancelled: return .orange
        default:         return .accentColor
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(transfer.statusLabel)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(statusColor.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Transfer formatting helpers

private extension Transfer {
    var sourceLabel: String {
        switch kind {
        case .download: return remotePath
        case .upload:   return localPath
        }
    }

    var destinationLabel: String {
        switch kind {
        case .download: return localPath
        case .upload:   return remotePath
        }
    }

    var formattedProgress: String {
        totalBytes > 0 ? String(format: "%.0f%%", progress * 100) : "—"
    }

    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesTransferred), countStyle: .file)
    }

    var formattedTotal: String {
        guard totalBytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }

    var statusLabel: String {
        switch status {
        case .completed: return "Done"
        case .failed:    return error ?? "Failed"
        case .cancelled: return "Cancelled"
        default:         return ""
        }
    }
}

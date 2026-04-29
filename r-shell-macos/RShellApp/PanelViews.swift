import SwiftUI
import RShellMacOS

// MARK: - Sidebar

struct SidebarPanel: View {
    @ObservedObject var storeManager: ConnectionStoreManager
    @Binding var selectedConnection: ConnectionProfile?
    var onConnect: ((ConnectionProfile) -> Void)?

    var body: some View {
        SidebarView(
            storeManager: storeManager,
            selectedConnection: $selectedConnection,
            onConnect: onConnect
        )
    }
}

// MARK: - Main workspace (terminals + files)

/// Vertical split mirroring the Tauri layout: terminal tabs on top
/// (always resident — see `terminalsPane` for the per-tab `ZStack`
/// rationale), file browser on the bottom. Both panes target the same
/// active connection (the focused tab). For SFTP-only profiles the
/// terminal pane shows a placeholder explaining that the host is
/// SFTP-only; the file browser still works.
struct MainPanel: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore

    var body: some View {
        VSplitView {
            terminalsPane
                .frame(minHeight: 200, idealHeight: 380)
            FileBrowserView(
                connectionId: tabsStore.activeTab?.connectionId,
                connectionLabel: tabsStore.activeTab?.profile.name ?? "No connection"
            )
            .frame(minHeight: 180, idealHeight: 260)
        }
    }

    @ViewBuilder
    private var terminalsPane: some View {
        VStack(spacing: 0) {
            TabBarView(
                tabs: tabsStore.tabs.map {
                    WorkspaceTab(
                        id: $0.id,
                        title: $0.title,
                        connectionId: $0.connectionId,
                        order: $0.order
                    )
                },
                activeTabId: Binding(
                    get: { tabsStore.activeTabId },
                    set: { id in if let id { tabsStore.setActive(id) } }
                ),
                onClose: { tab in tabsStore.closeTab(tab.id) },
                onNewTab: {},
                onSetTheme: { tab, themeId in
                    tabsStore.setTheme(themeId, forTabId: tab.id)
                },
                themeOverrides: Dictionary(
                    uniqueKeysWithValues: tabsStore.tabs.compactMap { tab in
                        tab.themeOverride.map { (tab.id, $0) }
                    }
                ),
                statuses: Dictionary(
                    uniqueKeysWithValues: tabsStore.tabs.map { ($0.id, $0.status) }
                )
            )

            Divider()

            if tabsStore.tabs.isEmpty {
                placeholder
            } else {
                // Render every open terminal once, stacked. Switching tabs
                // toggles `.opacity` and `allowsHitTesting`; the SwiftTerm
                // NSView for inactive tabs stays mounted, preserving its
                // scrollback, selection, cursor position, and any in-flight
                // PTY output that arrives while the tab is hidden.
                //
                // SwiftUI keeps each subview's identity stable via the tab
                // UUID, so `dismantleNSView` only fires when a tab is
                // actually closed (not on every switch).
                ZStack {
                    ForEach(tabsStore.tabs) { tab in
                        let isActive = tab.id == tabsStore.activeTabId
                        ZStack {
                            if tab.profile.kind.supportsTerminal {
                                TerminalView(
                                    connectionId: tab.connectionId,
                                    ptyGeneration: tab.ptyGeneration,
                                    themeOverride: tab.themeOverride,
                                    isActive: isActive,
                                    terminalTitle: .constant(tab.title),
                                    searchVisible: .constant(false),
                                    onSearchQueryChanged: nil,
                                    onSearchNext: nil,
                                    onSearchPrevious: nil
                                )

                                // Reconnect affordance — covers disconnected
                                // and errored tabs. The SwiftTerm view stays
                                // alive underneath so its scrollback isn't
                                // wiped; reconnect rebuilds only the PTY.
                                if tab.status == .disconnected || tab.status == .error {
                                    ReconnectOverlay(tab: tab) {
                                        Task { await tabsStore.reconnect(tabId: tab.id) }
                                    }
                                }
                            } else {
                                // SFTP-only profile: no PTY, no SwiftTerm.
                                // The file panel below the split is the
                                // actual interaction surface.
                                SftpOnlyPlaceholder(tab: tab)
                            }
                        }
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        // Stable per-tab identity — tab.id is generated
                        // once when the tab is created and never reused.
                        .id(tab.id)
                    }
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Select a connection from the sidebar to open a terminal")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A terminal tab opened from the sidebar.
struct TerminalTab: Identifiable {
    let id: UUID
    /// Carried so a Reconnect action after a network drop can re-run
    /// the connect flow with the same credentials.
    let profile: ConnectionProfile
    /// UUID-derived suffix so multiple tabs to the same host have
    /// distinct connection_ids in r-shell-core. Stable across
    /// reconnects so the rebuilt PTY routes to the same Swift session.
    let sessionId: String
    /// `user@host:port#sessionId` — looked up via this in the rest of
    /// the bridge. Stays the same across reconnects.
    let connectionId: String
    /// Generation counter from the most recent `rshellPtyStart` for
    /// this tab. `var` so reconnect can update it without rebuilding
    /// the SwiftTerm view.
    var ptyGeneration: UInt64
    var title: String
    var order: Int
    /// When non-nil, overrides the global `@AppStorage("terminalTheme")`.
    var themeOverride: String?
    /// Live connection state from the `connection_status` event bus.
    /// Defaults to `.connected` since we only build a tab after a
    /// successful `rshellConnect`.
    var status: TerminalConnectionStatus = .connected
}

// MARK: - SFTP-only placeholder

/// Shown in the terminals pane when the active tab is an SFTP-only
/// profile. The file panel underneath is the real interaction
/// surface; this view exists only to fill the slot where a terminal
/// would normally live.
private struct SftpOnlyPlaceholder: View {
    let tab: TerminalTab

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tint)
            Text(tab.profile.name)
                .font(.headline)
            Text("SFTP-only connection — no shell available.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Use the Files panel below to browse and transfer.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Reconnect overlay

private struct ReconnectOverlay: View {
    let tab: TerminalTab
    let onReconnect: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: tab.status == .error ? "exclamationmark.triangle.fill" : "wifi.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(tab.status == .error ? .red : .yellow)

            Text(tab.status == .error ? "Connection error" : "Disconnected")
                .font(.headline)

            Text("\(tab.profile.username)@\(tab.profile.host):\(tab.profile.port)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: onReconnect) {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.4))
    }
}

// MARK: - Bottom panel

struct BottomPanel: View {
    @EnvironmentObject var transfers: TransferQueueStore
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @State private var selectedSegment = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedSegment) {
                Text("Output").tag(0)
                Text("Logs").tag(1)
                Text("Problems").tag(2)
                // Badge the segment with active count when a transfer is
                // in flight — gives a glanceable signal even when the
                // user is on a different segment.
                let active = transfers.transfers.filter {
                    $0.status == .inProgress || $0.status == .queued
                }.count
                if active > 0 {
                    Text("Transfers (\(active))").tag(3)
                } else {
                    Text("Transfers").tag(3)
                }
                Text("Processes").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            Group {
                switch selectedSegment {
                case 0: emptyState("No output yet", systemImage: "terminal")
                case 1: emptyState("No logs", systemImage: "doc.text")
                case 2: emptyState("No problems detected", systemImage: "checkmark.seal")
                case 3: TransferQueueView(store: transfers)
                case 4:
                    ProcessListView(
                        connectionId: tabsStore.activeTab?.connectionId,
                        connectionLabel: tabsStore.activeTab?.profile.name ?? "No connection"
                    )
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: LayoutConstants.minBottomHeight)
    }

    private func emptyState(_ message: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Transfer queue view

private struct TransferQueueView: View {
    @ObservedObject var store: TransferQueueStore

    var body: some View {
        if store.transfers.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No file transfers")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                List {
                    ForEach(store.transfers) { transfer in
                        TransferRow(transfer: transfer) {
                            store.cancel(transferId: transfer.id)
                        }
                    }
                }
                .listStyle(.plain)

                // Footer with a Clear-completed button when there's
                // anything to clear.
                let cleanable = store.transfers.contains {
                    $0.status == .completed || $0.status == .failed || $0.status == .cancelled
                }
                if cleanable {
                    HStack {
                        Spacer()
                        Button("Clear Completed") { store.clearCompleted() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: transfer.kind == .download ? "arrow.down.doc" : "arrow.up.doc")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(transfer.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if transfer.status == .queued || transfer.status == .inProgress {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(transfer.status == .queued ? "Remove from queue" : "Cancel transfer")
                }

                statusBadge
            }

            // Progress bar — only render when we know the total. For
            // unknown-total uploads we fall back to a simple "X bytes"
            // line so the row doesn't show a misleading 0% bar.
            if transfer.status == .inProgress && transfer.totalBytes > 0 {
                ProgressView(value: transfer.progress)
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 6) {
                if transfer.totalBytes > 0 {
                    Text("\(formatBytes(transfer.bytesTransferred)) / \(formatBytes(transfer.totalBytes))")
                } else {
                    Text(formatBytes(transfer.bytesTransferred))
                }
                if let error = transfer.error {
                    Text("· \(error)")
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var statusBadge: some View {
        Group {
            switch transfer.status {
            case .queued:
                Text("Queued")
                    .foregroundStyle(.secondary)
            case .inProgress:
                Text("\(Int(transfer.progress * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.tint)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            case .cancelled:
                Text("Cancelled")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Inspector

/// Right-hand panel — System Monitor for the active tab. Mirrors the
/// Tauri layout's right column. Updates automatically when the user
/// switches tabs because `SystemMonitorView`'s `.task(id:)` is keyed on
/// `connectionId`.
struct InspectorPanel: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore

    var body: some View {
        SystemMonitorView(
            connectionId: tabsStore.activeTab?.connectionId,
            connectionLabel: tabsStore.activeTab?.profile.name ?? "No connection"
        )
        .frame(minWidth: LayoutConstants.minInspectorWidth)
    }
}

import SwiftUI
import RShellMacOS

// MARK: - Sidebar

struct SidebarPanel: View {
    @ObservedObject var storeManager: ConnectionStoreManager
    @Binding var selectedConnection: ConnectionProfile?
    @Binding var selectedSection: SidebarView.NavSection
    var onConnect: ((ConnectionProfile) -> Void)?

    var body: some View {
        SidebarView(
            storeManager: storeManager,
            selectedConnection: $selectedConnection,
            selectedSection: $selectedSection,
            onConnect: onConnect
        )
    }
}

// MARK: - Main workspace (terminals)

/// `MainPanel` consumes the shared `TerminalTabsStore` so the sidebar's
/// "connect" action populates tabs here. The store owns the FFI lifecycle
/// (SSH connect → PTY start → register session); `MainPanel` only renders.
///
/// Switches between the terminal stack and the SFTP file browser based
/// on the sidebar's `selectedSection`. Tabs (terminals) are always
/// resident — switching to Files just hides them.
struct MainPanel: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @Binding var selectedSection: SidebarView.NavSection

    var body: some View {
        switch selectedSection {
        case .terminals:
            terminalsPane
        case .files:
            FileBrowserView(
                connectionId: tabsStore.activeTab?.connectionId,
                connectionLabel: tabsStore.activeTab?.profile.name ?? "No connection"
            )
        case .monitor:
            monitorPlaceholder
        }
    }

    private var monitorPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("System monitoring lands in a future release.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var selectedSegment = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedSegment) {
                Text("Output").tag(0)
                Text("Logs").tag(1)
                Text("Problems").tag(2)
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

// MARK: - Inspector

struct InspectorPanel: View {
    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Host", value: "—")
                LabeledContent("Port", value: "—")
                LabeledContent("User", value: "—")
                LabeledContent("Status", value: "Disconnected")
            }

            Section {
                Label("Host keys are verified via TOFU (Trust On First Use).",
                      systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minWidth: LayoutConstants.minInspectorWidth)
    }
}

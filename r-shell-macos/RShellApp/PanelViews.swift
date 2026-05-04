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

/// Connection-level tab bar. Each tab represents a connected workspace,
/// not just a terminal surface: terminal, files, and monitor all follow
/// the selected tab together.
struct ConnectionTabBar: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @Binding var dashboardVisible: Bool

    private var connectedSSHTabs: [TerminalTab] {
        tabsStore.connectedSSHTabs
    }

    var body: some View {
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
            ),
            showsDashboardButton: connectedSSHTabs.count >= 2,
            dashboardVisible: dashboardVisible,
            onToggleDashboard: {
                dashboardVisible.toggle()
            }
        )
        .onChange(of: connectedSSHTabs.map(\.id)) { ids in
            if ids.count < 2 {
                dashboardVisible = false
            }
        }
    }
}

/// Layout switches based on each tab's `ConnectionKind`:
///
/// - `.ssh`: vertical split mirroring the Tauri layout — terminal
///   on top, file browser on the bottom. Both panes target the tab's
///   connection and stay mounted while inactive.
/// - `.sftp`: Midnight-Commander dual-pane file browser (remote left,
///   local right). The terminal section goes away.
///
/// When there's no tab, shows the "Connect to a host" placeholder.
struct MainPanel: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore

    var body: some View {
        if tabsStore.tabs.isEmpty {
            placeholder
        } else {
            // Render every open connection workspace once, stacked. Switching
            // tabs toggles visibility and hit testing; inactive workspaces
            // stay mounted so terminal scrollback, file-browser paths, and
            // dual-pane local/remote state survive tab switches.
            ZStack {
                ForEach(tabsStore.tabs) { tab in
                    let isActive = tab.id == tabsStore.activeTabId
                    connectionWorkspace(for: tab, isActive: isActive)
                        .overlay {
                            if tab.status == .disconnected || tab.status == .error {
                                ReconnectOverlay(tab: tab) {
                                    Task { await tabsStore.reconnect(tabId: tab.id) }
                                }
                            }
                        }
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .id(tab.id)
                }
            }
        }
    }

    @ViewBuilder
    private func connectionWorkspace(for tab: TerminalTab, isActive: Bool) -> some View {
        if tab.effectiveKind == .sftp {
            DualPaneFileBrowserView(
                connectionId: tab.connectionId,
                connectionLabel: tab.profile.name
            )
        } else {
            VSplitView {
                TerminalPane(tab: tab, isActive: isActive)

                DualPaneFileBrowserView(
                    connectionId: tab.connectionId,
                    connectionLabel: tab.profile.name,
                    canEditPermissions: true,
                    canRunRemoteCommands: true
                )
                .frame(minHeight: 180, idealHeight: 260)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Select a connection from the sidebar to open a workspace")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerminalPane: View {
    @EnvironmentObject private var tabsStore: TerminalTabsStore
    @AppStorage("terminalTheme") private var globalTerminalTheme = "system"

    let tab: TerminalTab
    let isActive: Bool

    private var activeTheme: TerminalTheme {
        TerminalTheme.resolve(tab.themeOverride ?? globalTerminalTheme)
    }

    private var globalTheme: TerminalTheme {
        TerminalTheme.resolve(globalTerminalTheme)
    }

    var body: some View {
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
        .padding(5)
        .frame(minHeight: 200, idealHeight: 380)
        .background(Color(activeTheme.background))
        .overlay(alignment: .topTrailing) {
            TerminalThemeSelector(
                currentThemeOverride: tab.themeOverride,
                globalTheme: globalTheme,
                activeTheme: activeTheme
            ) { themeId in
                tabsStore.setTheme(themeId, forTabId: tab.id)
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
    }
}

private struct TerminalThemeSelector: View {
    let currentThemeOverride: String?
    let globalTheme: TerminalTheme
    let activeTheme: TerminalTheme
    let onSetTheme: (String?) -> Void

    var body: some View {
        Menu {
            Button {
                onSetTheme(nil)
            } label: {
                Label(
                    "Use global (\(globalTheme.label))",
                    systemImage: currentThemeOverride == nil ? "checkmark" : ""
                )
            }
            Divider()
            ForEach(TerminalTheme.all) { theme in
                Button {
                    onSetTheme(theme.id)
                } label: {
                    Label(
                        theme.label,
                        systemImage: currentThemeOverride == theme.id ? "checkmark" : ""
                    )
                }
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(Color(activeTheme.foreground).opacity(0.85))
        .background(Color(activeTheme.background).opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
        .help("Terminal theme")
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
    /// Per-tab kind override. Set when `openConnection` falls back
    /// from SSH to SFTP because the server denied the shell channel
    /// (scponly, ForceCommand internal-sftp). The user's saved
    /// `profile.kind` is left untouched — flipping it would silently
    /// rewrite their settings — but the tab renders as SFTP for the
    /// rest of its lifetime. `effectiveKind` is the value the rest
    /// of the UI should consult; nothing should read `profile.kind`
    /// directly to decide layout.
    var kindOverride: ConnectionKind?

    /// Effective connection kind for this tab. Prefers an explicit
    /// override (set on shell-denied fallback) over the saved
    /// profile setting.
    var effectiveKind: ConnectionKind {
        kindOverride ?? profile.kind
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

// MARK: - Inspector

/// Right-hand panel — System Monitor for the active tab. Mirrors the
/// Tauri layout's right column. Updates automatically when the user
/// switches tabs because `SystemMonitorView`'s `.task(id:)` is keyed on
/// `connectionId`.
struct InspectorPanel: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore

    var body: some View {
        if tabsStore.tabs.isEmpty {
            SystemMonitorView(connectionId: nil, connectionLabel: "No connection")
                .frame(minWidth: LayoutConstants.minInspectorWidth)
        } else {
            ZStack {
                ForEach(tabsStore.tabs) { tab in
                    let isActive = tab.id == tabsStore.activeTabId
                    SystemMonitorView(
                        connectionId: tab.connectionId,
                        connectionLabel: tab.profile.name,
                        profileId: tab.profile.id,
                        sshPort: tab.profile.port,
                        profile: tab.profile,
                        connectionStatus: tab.status,
                        isActive: isActive
                    )
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .id(tab.id)
                }
            }
            .frame(minWidth: LayoutConstants.minInspectorWidth)
        }
    }
}

// MARK: - Multi-host dashboard

/// Full-width monitor desktop. Each connected SSH workspace renders the
/// same view used by the right inspector panel, with polling enabled for
/// every visible host.
struct DashboardPanel: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @ObservedObject private var activityLog = ActivityLogStore.shared
    @State private var sort = DashboardSort.order

    private var tabs: [TerminalTab] {
        let tabs = tabsStore.connectedSSHTabs
        switch sort {
        case .order:
            return tabs
        case .name:
            return tabs.sorted {
                $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending
            }
        case .host:
            return tabs.sorted {
                let lhs = "\($0.profile.host):\($0.profile.port)"
                let rhs = "\($1.profile.host):\($1.profile.port)"
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }
    }

    var body: some View {
        if tabs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Connect to two or more SSH hosts to open the dashboard.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                dashboardToolbar
                Divider()
                problemStrip
                Divider()
                comparisonStrip
                Divider()

                GeometryReader { proxy in
                    let columnWidth = max(
                        LayoutConstants.minInspectorWidth,
                        proxy.size.width / CGFloat(max(tabs.count, 1))
                    )

                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                SystemMonitorView(
                                    connectionId: tab.connectionId,
                                    connectionLabel: tab.profile.name,
                                    profileId: tab.profile.id,
                                    sshPort: tab.profile.port,
                                    profile: tab.profile,
                                    connectionStatus: tab.status,
                                    isActive: true
                                )
                                .frame(width: columnWidth)

                                if index < tabs.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .frame(
                            minWidth: proxy.size.width,
                            maxHeight: .infinity,
                            alignment: .leading
                        )
                    }
                }
            }
            .materialBackground(.contentBackground, blendingMode: .withinWindow)
        }
    }

    private var problemEvents: [ActivityLogEvent] {
        activityLog.recentProblems(limit: 5)
    }

    private var nonHealthyTabs: [TerminalTab] {
        tabsStore.tabs.filter { $0.status != .connected }
    }

    private var comparisonStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tabs, id: \.id) { tab in
                    dashboardHostCard(tab)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func dashboardHostCard(_ tab: TerminalTab) -> some View {
        let issueCount = activityLog.events.filter {
            ($0.profileId == tab.profile.id || $0.connectionId == tab.connectionId)
                && ($0.severity == .warning || $0.severity == .critical)
        }.count

        return Button {
            tabsStore.setActive(tab.id)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(tab.status == .connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.profile.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(tab.profile.username)@\(tab.profile.host):\(tab.profile.port)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if issueCount > 0 {
                    Text("\(issueCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Activate Host") { tabsStore.setActive(tab.id) }
            Button("Reconnect") { Task { await tabsStore.reconnect(tabId: tab.id) } }
            Button("Copy SSH Command") {
                RemoteCommandRunner.copy("ssh -p \(tab.profile.port) \(tab.profile.username)@\(tab.profile.host)")
            }
        }
    }

    private var problemStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if problemEvents.isEmpty && nonHealthyTabs.isEmpty {
                    Label("No active problems recorded in this workspace", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    ForEach(nonHealthyTabs, id: \.id) { tab in
                        dashboardProblemCard(
                            title: tab.profile.name,
                            detail: tab.status.rawValue.capitalized,
                            icon: "wifi.slash",
                            color: .orange
                        )
                    }
                    ForEach(problemEvents, id: \.id) { event in
                        dashboardProblemCard(
                            title: event.title,
                            detail: event.detail,
                            icon: event.icon,
                            color: event.severity.color
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func dashboardProblemCard(
        title: String,
        detail: String,
        icon: String,
        color: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var dashboardToolbar: some View {
        HStack(spacing: 10) {
            Label("\(tabs.count) hosts", systemImage: "server.rack")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Picker("Sort", selection: $sort) {
                ForEach(DashboardSort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private enum DashboardSort: String, CaseIterable, Identifiable {
    case order
    case name
    case host

    var id: String { rawValue }

    var label: String {
        switch self {
        case .order: return "Opened"
        case .name: return "Name"
        case .host: return "Host"
        }
    }
}

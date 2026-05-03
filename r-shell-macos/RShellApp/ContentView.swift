import SwiftUI
import RShellMacOS

/// Native macOS workspace — mirrors the Tauri 4-region layout.
///
///   ┌────────────────┬───────────────────┬────────────┐
///   │ Connections    │ Terminal tabs     │            │
///   │ (manager)      │ (always-visible)  │            │
///   ├────────────────│                   │  System    │
///   │ Connection     ├───────────────────┤  Monitor   │
///   │ Details        │ File browser      │  (always)  │
///   │                │ (always-visible)  │            │
///   ├────────────────┴───────────────────┤            │
///   │ Bottom: transfers / logs           │            │
///   └────────────────────────────────────┴────────────┘
///
/// Layout is an explicit outer `HSplitView` (sidebar | detail). The
/// detail column nests `HSplitView` + `VSplitView` so the three regions
/// (terminal-pane / file-pane / bottom / inspector) collapse and resize
/// independently. The three-column `NavigationSplitView` form can only
/// express `(all / doubleColumn / detailOnly)`, which doesn't allow
/// "sidebar visible, inspector hidden" — so the inspector lives inside
/// the detail column.
///
/// `LayoutManager` is the source of truth for which panels are visible
/// and at what size. The bottom-panel and inspector dividers are observed via
/// `GeometryReader` preferences and persisted through a 250 ms debounced
/// write.
struct ContentView: View {
    @EnvironmentObject var layoutManager: LayoutManager
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @StateObject private var connectionStore = ConnectionStoreManager.shared
    @StateObject private var transfersStore = TransferQueueStore()
    @State private var selectedConnection: ConnectionProfile?

    var body: some View {
        HSplitView {
            if layoutManager.layout.sidebarVisible {
                SidebarColumn(
                    layoutManager: layoutManager,
                    storeManager: connectionStore,
                    selectedConnection: $selectedConnection,
                    onConnect: { profile in
                        Task { await tabsStore.openConnection(profile) }
                    }
                )
            }

            DetailColumn(layoutManager: layoutManager)
        }
        .environmentObject(transfersStore)
        .frame(minWidth: 900, minHeight: 600)
        .alert("Connection error", isPresented: Binding(
            get: { tabsStore.lastError != nil },
            set: { if !$0 { tabsStore.lastError = nil } }
        )) {
            Button("OK") { tabsStore.lastError = nil }
        } message: {
            Text(tabsStore.lastError ?? "")
        }
        // SSH→SFTP fallback prompt. Distinct from the error alert
        // because the connect *did* succeed, just in a different
        // shape than asked for. Offers a one-click commit to make
        // the demotion permanent so future connects skip the shell
        // attempt entirely.
        .alert("Server doesn't allow shell access",
               isPresented: Binding(
                   get: { tabsStore.pendingFallback != nil },
                   set: { if !$0 { tabsStore.pendingFallback = nil } }
               ),
               presenting: tabsStore.pendingFallback
        ) { fallback in
            Button("Convert profile to SFTP") {
                connectionStore.setKind(profileId: fallback.profileId, kind: .sftp)
                tabsStore.pendingFallback = nil
            }
            Button("Keep as SSH", role: .cancel) {
                tabsStore.pendingFallback = nil
            }
        } message: { fallback in
            Text(fallback.message)
        }
    }
}

// MARK: - Sidebar column

private struct SidebarColumn: View {
    @ObservedObject var layoutManager: LayoutManager
    @ObservedObject var storeManager: ConnectionStoreManager
    @Binding var selectedConnection: ConnectionProfile?
    let onConnect: (ConnectionProfile) -> Void
    @State private var sidebarWidthDebounce: Task<Void, Never>?

    var body: some View {
        SidebarView(
            storeManager: storeManager,
            selectedConnection: $selectedConnection,
            onConnect: onConnect
        )
        .finderSidebarBackground()
        .frame(
            minWidth: LayoutConstants.minSidebarWidth,
            idealWidth: layoutManager.layout.sidebarWidth,
            maxWidth: LayoutConstants.maxSidebarWidth
        )
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SidebarWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(SidebarWidthKey.self, perform: persistSidebarWidth)
    }

    private func persistSidebarWidth(_ measured: CGFloat) {
        sidebarWidthDebounce?.cancel()
        sidebarWidthDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            let clamped = min(
                max(measured, LayoutConstants.minSidebarWidth),
                LayoutConstants.maxSidebarWidth
            )
            if abs(clamped - layoutManager.layout.sidebarWidth) > 1 {
                layoutManager.layout.sidebarWidth = clamped
            }
        }
    }
}

// MARK: - Detail column (main + bottom + inspector)

private struct DetailColumn: View {
    @ObservedObject var layoutManager: LayoutManager
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @State private var bottomHeightDebounce: Task<Void, Never>?
    @State private var inspectorWidthDebounce: Task<Void, Never>?
    @State private var dashboardVisible = false

    /// Connection utility panels are shown only for the selected, open SSH
    /// workspace. SFTP-only tabs, no tab, and disconnected SSH tabs hide
    /// these command-driven panels while preserving the user's persisted
    /// visible/size preferences for the next connected SSH tab.
    private var bottomShouldRender: Bool {
        layoutManager.layout.bottomVisible && tabsStore.activeOpenSSHTab != nil
    }

    private var inspectorShouldRender: Bool {
        layoutManager.layout.inspectorVisible && tabsStore.activeOpenSSHTab != nil
    }

    private var dashboardShouldRender: Bool {
        dashboardVisible && tabsStore.connectedSSHTabs.count >= 2
    }

    private var connectedSSHTabIds: [UUID] {
        tabsStore.connectedSSHTabs.map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !tabsStore.tabs.isEmpty {
                ConnectionTabBar(dashboardVisible: $dashboardVisible)
                Divider()
            }

            if dashboardShouldRender {
                DashboardPanel()
                    .frame(minWidth: 320, minHeight: 320)
            } else {
                HSplitView {
                    VSplitView {
                        MainPanel()
                            .frame(minWidth: 320, minHeight: 320)

                        if bottomShouldRender {
                            BottomPanel()
                                .frame(
                                    minHeight: LayoutConstants.minBottomHeight,
                                    idealHeight: layoutManager.layout.bottomHeight,
                                    maxHeight: LayoutConstants.maxBottomHeight
                                )
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear
                                            .preference(key: BottomHeightKey.self,
                                                        value: proxy.size.height)
                                    }
                                )
                                .materialBackground(.contentBackground,
                                                    blendingMode: .withinWindow)
                        }
                    }
                    .onPreferenceChange(BottomHeightKey.self, perform: persistBottomHeight)

                    if inspectorShouldRender {
                        InspectorPanel()
                            .frame(
                                minWidth: LayoutConstants.minInspectorWidth,
                                idealWidth: layoutManager.layout.inspectorWidth,
                                maxWidth: LayoutConstants.maxInspectorWidth
                            )
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(key: InspectorWidthKey.self,
                                                    value: proxy.size.width)
                                }
                            )
                            .materialBackground(.contentBackground,
                                                blendingMode: .withinWindow)
                    }
                }
            }
        }
        .onPreferenceChange(InspectorWidthKey.self, perform: persistInspectorWidth)
        .onChange(of: connectedSSHTabIds) { ids in
            if ids.count < 2 {
                dashboardVisible = false
            }
        }
    }

    /// Debounce drag updates: split views fire preference changes on every
    /// frame while the user drags, *and* every frame during a window
    /// resize. We coalesce to one disk write 250 ms after the last update,
    /// and clamp to the configured min/max so a transient `0` (e.g.,
    /// during reappearance after toggle) cannot corrupt the persisted
    /// dimension.
    ///
    /// Note: this means the persisted dimension drifts with window
    /// resizes, since the split view rebalances proportionally. That's
    /// the trade-off for keeping the persistence path simple — there is
    /// no reliable "drag began / drag ended" callback on `HSplitView` /
    /// `VSplitView` to differentiate user drag from system reflow.
    private func persistBottomHeight(_ measured: CGFloat) {
        bottomHeightDebounce?.cancel()
        bottomHeightDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            let clamped = min(
                max(measured, LayoutConstants.minBottomHeight),
                LayoutConstants.maxBottomHeight
            )
            if abs(clamped - layoutManager.layout.bottomHeight) > 1 {
                layoutManager.layout.bottomHeight = clamped
            }
        }
    }

    private func persistInspectorWidth(_ measured: CGFloat) {
        inspectorWidthDebounce?.cancel()
        inspectorWidthDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            let clamped = min(
                max(measured, LayoutConstants.minInspectorWidth),
                LayoutConstants.maxInspectorWidth
            )
            if abs(clamped - layoutManager.layout.inspectorWidth) > 1 {
                layoutManager.layout.inspectorWidth = clamped
            }
        }
    }
}

// MARK: - Preference keys for split-pane dimensions

private struct BottomHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct InspectorWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SidebarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

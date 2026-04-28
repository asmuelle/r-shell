import SwiftUI
import RShellMacOS

/// Native macOS workspace.
///
///   ┌──────────┬──────────────────────┬────────────┐
///   │          │   Main (terminals)   │            │
///   │ Sidebar  ├──────────────────────│ Inspector  │
///   │ (vibr.)  │   Bottom (logs)      │ (vibrancy) │
///   └──────────┴──────────────────────┴────────────┘
///
/// Layout is a two-column `NavigationSplitView` (sidebar | detail). The
/// detail column owns the main / bottom / inspector layout via nested
/// `HSplitView` + `VSplitView`. This is what lets the three panels
/// collapse independently — the three-column `NavigationSplitView` form
/// can only express `(all / doubleColumn / detailOnly)`, which doesn't
/// allow "sidebar visible, inspector hidden" as a distinct state.
///
/// `LayoutManager` is the source of truth for which panels are visible
/// and at what size. The system-driven sidebar collapse (toolbar button,
/// trackpad swipe, View menu) round-trips through `sidebarVisibility`.
/// The bottom-panel divider is observed via a `GeometryReader` preference
/// and persisted through a 250 ms debounced write.
struct ContentView: View {
    @EnvironmentObject var layoutManager: LayoutManager
    @StateObject private var connectionStore = ConnectionStoreManager.shared
    @State private var selectedConnection: ConnectionProfile?
    @State private var selectedSection: SidebarView.NavSection = .terminals

    /// Two-way bridge between the system column-visibility enum and the
    /// persisted `layout.sidebarVisible` flag.
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { layoutManager.layout.sidebarVisible ? .all : .detailOnly },
            set: { newValue in
                layoutManager.layout.sidebarVisible = (newValue != .detailOnly)
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(
                storeManager: connectionStore,
                selectedConnection: $selectedConnection,
                selectedSection: $selectedSection
            )
            .materialBackground(.sidebar)
            .navigationSplitViewColumnWidth(
                min: LayoutConstants.minSidebarWidth,
                ideal: layoutManager.layout.sidebarWidth,
                max: LayoutConstants.maxSidebarWidth
            )
        } detail: {
            DetailColumn(layoutManager: layoutManager)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Detail column (main + bottom + inspector)

private struct DetailColumn: View {
    @ObservedObject var layoutManager: LayoutManager
    @State private var bottomHeightDebounce: Task<Void, Never>?
    @State private var inspectorWidthDebounce: Task<Void, Never>?

    var body: some View {
        HSplitView {
            VSplitView {
                MainPanel()
                    .frame(minWidth: 320, minHeight: 200)

                if layoutManager.layout.bottomVisible {
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

            if layoutManager.layout.inspectorVisible {
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
        .onPreferenceChange(InspectorWidthKey.self, perform: persistInspectorWidth)
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

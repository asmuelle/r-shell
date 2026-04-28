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

struct MainPanel: View {
    @State private var tabs: [TerminalTab] = []
    @State private var activeTabId: UUID?
    @State private var searchVisible: [UUID: Bool] = [:]
    @State private var searchQuery: [UUID: String] = [:]
    @State private var searchMatchIndex: [UUID: Int] = [:]
    @State private var searchMatchCount: [UUID: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(
                tabs: tabs.map { WorkspaceTab(id: $0.id, title: $0.title, connectionId: $0.connectionId, order: $0.order) },
                activeTabId: $activeTabId,
                onClose: { tab in
                    if let t = tabs.first(where: { $0.id == tab.id }) {
                        TerminalSessionManager.shared.unregisterSession(connectionId: t.connectionId)
                    }
                    tabs.removeAll { $0.id == tab.id }
                    searchVisible.removeValue(forKey: tab.id)
                    searchQuery.removeValue(forKey: tab.id)
                    if activeTabId == tab.id {
                        activeTabId = tabs.last?.id
                    }
                },
                onNewTab: {}
            )

            Divider()

            if let activeTabId,
               let active = tabs.first(where: { $0.id == activeTabId }) {
                ZStack(alignment: .topTrailing) {
                    TerminalView(
                        connectionId: active.connectionId,
                        ptyGeneration: active.ptyGeneration,
                        terminalTitle: .constant(active.title),
                        searchVisible: .constant(searchVisible[activeTabId] ?? false),
                        onSearchQueryChanged: { q in
                            searchQuery[activeTabId] = q
                        },
                        onSearchNext: {},
                        onSearchPrevious: {}
                    )

                    if searchVisible[activeTabId] == true {
                        VStack {
                            TerminalSearchBar(
                                query: .constant(searchQuery[activeTabId] ?? ""),
                                isVisible: .constant(true),
                                matchCount: searchMatchCount[activeTabId] ?? 0,
                                currentMatch: searchMatchIndex[activeTabId] ?? 0,
                                onNext: {},
                                onPrevious: {},
                                onClose: { searchVisible[activeTabId] = false }
                            )
                            Spacer()
                        }
                    }
                }
                .onAppear { installKeyboardHandlers(for: activeTabId) }
            } else {
                placeholder
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

    private func installKeyboardHandlers(for tabId: UUID) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case "f":
                    searchVisible[tabId] = true
                    return nil
                case "g" where event.modifierFlags.contains(.shift):
                    searchMatchIndex[tabId] = min(
                        (searchMatchIndex[tabId] ?? 0) + 1,
                        max((searchMatchCount[tabId] ?? 1) - 1, 0)
                    )
                    return nil
                case "g":
                    searchMatchIndex[tabId] = max((searchMatchIndex[tabId] ?? 0) - 1, 0)
                    return nil
                default:
                    break
                }
            }
            if event.keyCode == 53 && searchVisible[tabId] == true { // Escape
                searchVisible[tabId] = false
                return nil
            }
            return event
        }
    }
}

/// A terminal tab opened from the sidebar.
struct TerminalTab: Identifiable {
    let id: UUID
    let connectionId: String
    let ptyGeneration: UInt64
    var title: String
    var order: Int
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

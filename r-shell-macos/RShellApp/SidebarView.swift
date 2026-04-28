import SwiftUI
import RShellMacOS

/// Sidebar showing navigation items and saved connections grouped by folder.
struct SidebarView: View {
    @ObservedObject var storeManager: ConnectionStoreManager
    @Binding var selectedConnection: ConnectionProfile?
    @Binding var selectedSection: NavSection
    var onConnect: ((ConnectionProfile) -> Void)?

    @State private var showNewConnection = false
    @State private var showImport = false
    @State private var search = ""
    /// When non-nil, presents the edit sheet for the wrapped profile.
    /// Driving via `.sheet(item:)` rather than a Bool + separate state
    /// gives SwiftUI an identity-stable handle so flipping between
    /// profiles in the context menu doesn't reuse the previous form.
    @State private var editingProfile: EditTarget?

    private struct EditTarget: Identifiable {
        let profile: ConnectionProfile
        var id: String { profile.id }
    }

    enum NavSection: String, CaseIterable, Identifiable {
        case terminals
        case files
        case monitor

        var id: String { rawValue }
        var label: String {
            switch self {
            case .terminals: return "Terminals"
            case .files: return "Files"
            case .monitor: return "Monitor"
            }
        }
        var icon: String {
            switch self {
            case .terminals: return "terminal"
            case .files: return "folder"
            case .monitor: return "chart.bar.xaxis"
            }
        }
    }

    var body: some View {
        List(selection: $selectedConnection) {
            Section("Navigate") {
                ForEach(NavSection.allCases) { section in
                    Label(section.label, systemImage: section.icon)
                        .font(.system(size: 12))
                        .foregroundColor(selectedSection == section ? .accentColor : .primary)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedSection = section }
                }
            }

            if filteredRootConnections.isEmpty && filteredFolders.isEmpty {
                Section("Connections") {
                    if search.isEmpty && storeManager.connections.isEmpty {
                        // First-time onboarding — the toolbar `+` is easy
                        // to miss, so surface a real CTA with both
                        // entry points spelled out.
                        emptyState
                    } else {
                        Text(search.isEmpty ? "No saved connections" : "No matches")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            } else {
                if !filteredRootConnections.isEmpty {
                    Section("Connections") {
                        ForEach(filteredRootConnections) { conn in
                            ConnectionRow(profile: conn)
                                .tag(conn as ConnectionProfile?)
                                .onTapGesture {
                                    selectedSection = .terminals
                                    selectedConnection = conn
                                    onConnect?(conn)
                                }
                                .contextMenu { connectionContextMenu(conn) }
                        }
                    }
                }

                ForEach(filteredFolders) { folder in
                    Section(folder.name) {
                        ForEach(filteredConnections(in: folder.path)) { conn in
                            ConnectionRow(profile: conn)
                                .tag(conn as ConnectionProfile?)
                                .onTapGesture {
                                    selectedSection = .terminals
                                    selectedConnection = conn
                                    onConnect?(conn)
                                }
                                .contextMenu { connectionContextMenu(conn) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .searchable(text: $search, placement: .sidebar, prompt: "Search connections")
        .frame(minWidth: LayoutConstants.minSidebarWidth)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Connection") { showNewConnection = true }
                    Button("Import from Tauri…") { showImport = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewConnection) {
            ConnectionEditView(storeManager: storeManager, existingProfile: nil)
        }
        .sheet(item: $editingProfile) { target in
            ConnectionEditView(storeManager: storeManager, existingProfile: target.profile)
        }
        .fileImporter(
            isPresented: $showImport,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = storeManager.importFromTauriJSON(url: url)
            }
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Welcome to R-Shell")
                    .font(.headline)
            }

            Text("Add a saved SSH profile to start a session. Existing profiles from the Tauri build can be imported.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button {
                    showNewConnection = true
                } label: {
                    Label("New Connection…", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    showImport = true
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Filtering

    private func matches(_ conn: ConnectionProfile) -> Bool {
        guard !search.isEmpty else { return true }
        let needle = search.lowercased()
        return conn.name.lowercased().contains(needle)
            || conn.host.lowercased().contains(needle)
    }

    private var rootConnections: [ConnectionProfile] {
        storeManager.connections.filter { $0.folderPath == nil || $0.folderPath?.isEmpty == true }
    }

    private var filteredRootConnections: [ConnectionProfile] {
        rootConnections.filter(matches)
    }

    private var filteredFolders: [ConnectionFolder] {
        storeManager.folders.filter { folder in
            !filteredConnections(in: folder.path).isEmpty
        }
    }

    private func filteredConnections(in path: String) -> [ConnectionProfile] {
        storeManager.connections(inFolder: path).filter(matches)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func connectionContextMenu(_ conn: ConnectionProfile) -> some View {
        Button("Connect Terminal") {
            selectedConnection = conn
            selectedSection = .terminals
            onConnect?(conn)
        }
        Button("Open Monitor") {
            selectedConnection = conn
            selectedSection = .monitor
        }
        Divider()
        Button("Edit…") {
            editingProfile = EditTarget(profile: conn)
        }
        Button("Duplicate") {
            var copy = conn
            copy.id = UUID().uuidString
            copy.name = "\(conn.name) (copy)"
            storeManager.saveOrUpdate(copy)
        }
        Divider()
        Button("Delete", role: .destructive) { storeManager.delete(conn) }
    }
}

// MARK: - Row

/// Single connection row in the sidebar list. Two lines: name on top,
/// `user@host:port` underneath in caption style. Star prefix when the
/// profile is marked favorite.
struct ConnectionRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: profile.favorite ? "star.fill" : "network")
                .font(.system(size: 11))
                .foregroundStyle(profile.favorite ? .yellow : .secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text("\(profile.username)@\(profile.host):\(profile.port)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

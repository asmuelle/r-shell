import SwiftUI
import RShellMacOS

/// Sidebar showing the Connection Manager (top, scrollable) and a
/// Connection Details panel (bottom, fixed) for the currently-selected
/// profile. Mirrors the Tauri layout's left column. Connection Details
/// is empty when nothing is selected.
struct SidebarView: View {
    @ObservedObject var storeManager: ConnectionStoreManager
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @Binding var selectedConnection: ConnectionProfile?
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

    var body: some View {
        VSplitView {
            connectionList
            ConnectionDetailsPanel(profile: selectedConnection)
                .frame(minHeight: 140, idealHeight: 200, maxHeight: 320)
        }
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

    // MARK: - Connection list

    @ViewBuilder
    private var connectionList: some View {
        List(selection: $selectedConnection) {
            if filteredRootConnections.isEmpty && filteredFolders.isEmpty {
                Section("Connections") {
                    if search.isEmpty && storeManager.connections.isEmpty {
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
                            ConnectionRow(
                                profile: conn,
                                isConnecting: isConnecting(conn)
                            )
                            .tag(conn as ConnectionProfile?)
                            .onTapGesture { handleTap(conn) }
                            .contextMenu { connectionContextMenu(conn) }
                        }
                    }
                }

                ForEach(filteredFolders) { folder in
                    Section(folder.name) {
                        ForEach(filteredConnections(in: folder.path)) { conn in
                            ConnectionRow(
                                profile: conn,
                                isConnecting: isConnecting(conn)
                            )
                            .tag(conn as ConnectionProfile?)
                            .onTapGesture { handleTap(conn) }
                            .contextMenu { connectionContextMenu(conn) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .searchable(text: $search, placement: .sidebar, prompt: "Search connections")
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
        Button(conn.kind.supportsTerminal ? "Connect" : "Connect (SFTP)") {
            handleTap(conn)
        }
        .disabled(isConnecting(conn))
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

    // MARK: - Click + connecting state

    /// Whether `openConnection` is currently in flight for this
    /// profile. Driven by `TerminalTabsStore.connectingProfileIds`,
    /// which the store toggles around the entire connect → PTY-start
    /// sequence (auth retries included).
    private func isConnecting(_ conn: ConnectionProfile) -> Bool {
        tabsStore.connectingProfileIds.contains(conn.id)
    }

    /// Single tap entry point for both row clicks and the context-menu
    /// Connect button. Early-returns when the profile is already
    /// in-flight so a rapid double-tap (or a Return-key press while
    /// the tap's connect is still negotiating) can't queue a second
    /// session.
    private func handleTap(_ conn: ConnectionProfile) {
        guard !isConnecting(conn) else { return }
        selectedConnection = conn
        onConnect?(conn)
    }
}

// MARK: - Connection details panel

/// Bottom half of the sidebar — shows static metadata for the selected
/// profile. Mirrors the Tauri "Connection Details" card. Empty state
/// renders a hint instead of an empty form.
private struct ConnectionDetailsPanel: View {
    let profile: ConnectionProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connection Details")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            if let profile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        detailRow("Name", profile.name)
                        detailRow("Host", profile.host)
                        detailRow("Port", "\(profile.port)")
                        detailRow("User", profile.username)
                        detailRow("Protocol", profile.kind.displayName)
                        detailRow("Auth", profile.authMethod.displayName)
                        if let last = profile.lastConnected {
                            detailRow(
                                "Last Connected",
                                last.formatted(.relative(presentation: .named))
                            )
                        }
                        if !profile.tags.isEmpty {
                            detailRow("Tags", profile.tags.joined(separator: ", "))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Select a connection to see details.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Row

/// Single connection row in the sidebar list. Two lines: name on top,
/// `user@host:port` underneath in caption style. Star prefix when the
/// profile is marked favorite.
struct ConnectionRow: View {
    let profile: ConnectionProfile
    /// `true` while `TerminalTabsStore.openConnection` is in flight
    /// for this profile. Replaces the leading glyph with a spinner,
    /// dims the row, and (via the parent's tap guard) blocks further
    /// clicks until the connect either succeeds or fails.
    var isConnecting: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // Leading slot: spinner during connect, otherwise the
            // kind / favorite glyph.
            ZStack {
                if isConnecting {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: rowGlyph)
                        .font(.system(size: 11))
                        .foregroundStyle(rowGlyphTint)
                }
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if isConnecting {
                    // Replace the host string with a status line so
                    // users get unambiguous feedback that the click
                    // actually did something. `.tint` matches the
                    // spinner so the two read as one signal.
                    Text("Connecting…")
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                } else {
                    Text("\(profile.username)@\(profile.host):\(profile.port)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(isConnecting ? 0.7 : 1.0)
        // Click guarding lives in the parent's `handleTap` rather
        // than `.allowsHitTesting(false)` here — disabling hit-testing
        // would also kill the right-click that opens the context
        // menu, which is still useful (Edit, Delete) during connect.
        .accessibilityLabel(accessibilityLabel)
    }

    private var rowGlyph: String {
        if profile.favorite { return "star.fill" }
        switch profile.kind {
        case .ssh: return "terminal"
        case .sftp: return "folder.badge.gearshape"
        }
    }

    private var rowGlyphTint: Color {
        profile.favorite ? .yellow : .secondary
    }

    private var accessibilityLabel: String {
        let base = "\(profile.name), \(profile.username)@\(profile.host):\(profile.port)"
        return isConnecting ? "\(base), connecting" : base
    }
}

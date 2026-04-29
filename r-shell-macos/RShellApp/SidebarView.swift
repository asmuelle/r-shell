import SwiftUI
import RShellMacOS
import UniformTypeIdentifiers

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
    /// Disclosure state per folder path. Defaults to `true` so the
    /// hierarchy reads as fully open on first launch — the user
    /// collapses what they don't need.
    @State private var expandedFolders: [String: Bool] = [:]
    /// Folder mutation prompts (create / rename) and last error.
    @State private var folderPrompt: FolderPrompt?
    @State private var folderError: String?
    /// `true` while a drag is hovering the "move to root" drop row.
    /// Drives the row's tinted accent so users see the target light
    /// up the same way folder rows do during a drop hover.
    @State private var rootDropTargeted = false

    private struct EditTarget: Identifiable {
        let profile: ConnectionProfile
        var id: String { profile.id }
    }

    /// Encapsulates the four folder-naming prompts (new top-level, new
    /// subfolder, rename) so a single sheet can drive all three.
    private struct FolderPrompt: Identifiable {
        enum Kind { case createTopLevel, createSubfolder(parent: String), rename(folderId: String, current: String) }
        let id = UUID()
        let kind: Kind
        var title: String {
            switch kind {
            case .createTopLevel: return "New Folder"
            case .createSubfolder: return "New Subfolder"
            case .rename: return "Rename Folder"
            }
        }
        var initialName: String {
            if case .rename(_, let current) = kind { return current }
            return ""
        }
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
                    Button("New Folder") {
                        folderPrompt = FolderPrompt(kind: .createTopLevel)
                    }
                    Divider()
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
        .sheet(item: $folderPrompt) { prompt in
            FolderNameSheet(
                title: prompt.title,
                initialName: prompt.initialName
            ) { newName in
                applyFolderPrompt(prompt, name: newName)
            }
        }
        .alert(
            "Folder error",
            isPresented: Binding(
                get: { folderError != nil },
                set: { if !$0 { folderError = nil } }
            )
        ) {
            Button("OK") { folderError = nil }
        } message: {
            Text(folderError ?? "")
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
            if storeManager.connections.isEmpty && storeManager.folders.isEmpty {
                Section {
                    if search.isEmpty {
                        emptyState
                    } else {
                        Text("No matches")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                } header: {
                    SidebarSectionHeader(title: "Connections")
                }
            } else if isSearchActive && !hasAnyMatches {
                Section {
                    Text("No matches")
                        .foregroundColor(.secondary)
                        .font(.caption)
                } header: {
                    SidebarSectionHeader(title: "Connections")
                }
            } else {
                Section {
                    // Root-level (uncategorized) profiles first.
                    let rootConns = filteredConnections(in: nil)
                    ForEach(rootConns) { conn in
                        connectionRow(conn)
                    }

                    // Top-level folders, recursively rendered. Drag-drop
                    // and "Move to" context menus reorganize the
                    // hierarchy without users having to edit the profile.
                    ForEach(filteredChildFolders(of: nil)) { folder in
                        folderNode(folder)
                    }

                    // "Drop here to move to root" target — only
                    // visible when there's at least one folder, since
                    // dropping at root doesn't make sense without
                    // somewhere to drop *out of*. Lives at the bottom
                    // of the section as a faint "Move to top level"
                    // hint that activates as a real row when a drag
                    // hovers it. Section *headers* don't reliably
                    // accept drops in SwiftUI's sidebar List, so the
                    // drop target needs to be a body row.
                    if !storeManager.folders.isEmpty {
                        rootDropRow
                    }
                } header: {
                    SidebarSectionHeader(title: "Connections")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Search moves to the window toolbar (Finder-style) rather
        // than living inside the sidebar — keeps the sidebar visually
        // tighter and matches the platform convention.
        .searchable(text: $search, placement: .toolbar, prompt: "Search connections")
    }

    /// Recursive folder + nested-content renderer. Each folder is a
    /// `DisclosureGroup` keyed on its path so expansion state survives
    /// reorderings. Profiles inside the folder render as plain rows;
    /// child folders recurse — the `AnyView` wrapper is required
    /// because Swift's opaque-result-type rules forbid a function
    /// from returning `some View` defined in terms of itself.
    ///
    /// Folder rows are themselves `.draggable` so users can
    /// reparent a whole sub-tree by dragging it onto another folder.
    /// Two `.dropDestination` modifiers stack — one for connections
    /// and one for nested folders — because SwiftUI requires a
    /// distinct destination per accepted Transferable type. The
    /// store's `moveFolder` rejects cycles, so dropping "Work" onto
    /// "Work/Production" raises a `FolderError.duplicate` which
    /// surfaces via the existing `folderError` alert.
    private func folderNode(_ folder: ConnectionFolder) -> AnyView {
        AnyView(
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedFolders[folder.path] ?? true },
                    set: { expandedFolders[folder.path] = $0 }
                )
            ) {
                ForEach(filteredConnections(in: folder.path)) { conn in
                    connectionRow(conn)
                }
                ForEach(filteredChildFolders(of: folder.path)) { sub in
                    folderNode(sub)
                }
            } label: {
                FolderRow(folder: folder)
                    .contextMenu { folderContextMenu(folder) }
                    .draggable(FolderMove(folderId: folder.id))
            }
            .dropDestination(for: ProfileMove.self) { drops, _ in
                for drop in drops {
                    storeManager.moveProfile(id: drop.profileId, to: folder.path)
                }
                return !drops.isEmpty
            }
            .dropDestination(for: FolderMove.self) { drops, _ in
                for drop in drops {
                    do {
                        try storeManager.moveFolder(id: drop.folderId, to: folder.path)
                    } catch {
                        folderError = error.localizedDescription
                    }
                }
                return !drops.isEmpty
            }
        )
    }

    /// Faint "drop here to move to root" affordance. Tinted accent
    /// while a drag hovers, otherwise reads as a quiet hint at the
    /// bottom of the connections section. Accepts both `ProfileMove`
    /// and `FolderMove` payloads — symmetrical with what folder
    /// nodes accept, just routed to `nil` parent.
    @ViewBuilder
    private var rootDropRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.to.line")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            Text("Move to top level")
                .font(.system(size: 11))
                .foregroundStyle(rootDropTargeted
                    ? AnyShapeStyle(Color.accentColor)
                    : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(rootDropTargeted ? 0.18 : 0))
        )
        .dropDestination(for: ProfileMove.self) { drops, _ in
            for drop in drops {
                storeManager.moveProfile(id: drop.profileId, to: nil)
            }
            return !drops.isEmpty
        } isTargeted: { hovering in
            rootDropTargeted = hovering
        }
        .dropDestination(for: FolderMove.self) { drops, _ in
            for drop in drops {
                do {
                    try storeManager.moveFolder(id: drop.folderId, to: nil)
                } catch {
                    folderError = error.localizedDescription
                }
            }
            return !drops.isEmpty
        } isTargeted: { hovering in
            rootDropTargeted = hovering
        }
    }

    /// Wraps a connection row with the tap / context-menu / drag
    /// behaviour. Pulled out so root-level and folder-nested rows
    /// share a single definition.
    @ViewBuilder
    private func connectionRow(_ conn: ConnectionProfile) -> some View {
        ConnectionRow(
            profile: conn,
            isConnecting: isConnecting(conn)
        )
        .tag(conn as ConnectionProfile?)
        .onTapGesture { handleTap(conn) }
        .contextMenu { connectionContextMenu(conn) }
        .draggable(ProfileMove(profileId: conn.id))
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

    private var isSearchActive: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func matches(_ conn: ConnectionProfile) -> Bool {
        guard isSearchActive else { return true }
        let needle = search.lowercased()
        return conn.name.lowercased().contains(needle)
            || conn.host.lowercased().contains(needle)
            || conn.username.lowercased().contains(needle)
    }

    /// Profiles directly inside `folderPath` (or root when `nil`),
    /// already filtered by the active search needle. The "directly"
    /// part is important — descendant profiles render under their
    /// own folder node, so duplicating them at every ancestor would
    /// double-count.
    private func filteredConnections(in folderPath: String?) -> [ConnectionProfile] {
        storeManager.connections(inFolder: folderPath)
            .filter(matches)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Folders directly under `parent`, kept only when they (or any
    /// descendant) host at least one matching connection during a
    /// search. Without this, an active filter would still render
    /// empty parent folders just because the path exists.
    private func filteredChildFolders(of parent: String?) -> [ConnectionFolder] {
        storeManager.childFolders(of: parent).filter { folder in
            !isSearchActive || folderHasMatch(folder)
        }
    }

    /// Recursive existence check: does this folder, or any folder
    /// nested below it, contain a connection that matches the active
    /// search needle? Used by `filteredChildFolders` to prune empty
    /// branches during search.
    private func folderHasMatch(_ folder: ConnectionFolder) -> Bool {
        if !filteredConnections(in: folder.path).isEmpty { return true }
        for child in storeManager.childFolders(of: folder.path) {
            if folderHasMatch(child) { return true }
        }
        return false
    }

    private var hasAnyMatches: Bool {
        !filteredConnections(in: nil).isEmpty
            || storeManager.childFolders(of: nil).contains(where: folderHasMatch)
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
        moveToMenu(for: conn)
        Divider()
        Button("Delete", role: .destructive) { storeManager.delete(conn) }
    }

    /// "Move to" submenu listing every folder plus a "(Root)" entry.
    /// Disabling the option that points at the profile's current
    /// folder makes the current location glanceable without a
    /// separate checkmark column.
    @ViewBuilder
    private func moveToMenu(for conn: ConnectionProfile) -> some View {
        Menu("Move to") {
            Button("(Root)") {
                storeManager.moveProfile(id: conn.id, to: nil)
            }
            .disabled(conn.folderPath == nil)

            let paths = storeManager.allFolderPaths()
            if !paths.isEmpty { Divider() }
            ForEach(paths, id: \.self) { path in
                Button(path) {
                    storeManager.moveProfile(id: conn.id, to: path)
                }
                .disabled(conn.folderPath == path)
            }
            Divider()
            Button("New Folder…") {
                folderPrompt = FolderPrompt(kind: .createTopLevel)
                // The user creates the folder, then they Move-to it
                // explicitly — keeping this flow simple beats trying
                // to chain "create + move" through the prompt sheet.
            }
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: ConnectionFolder) -> some View {
        Button("New Subfolder") {
            folderPrompt = FolderPrompt(kind: .createSubfolder(parent: folder.path))
        }
        Button("Rename…") {
            folderPrompt = FolderPrompt(kind: .rename(folderId: folder.id, current: folder.name))
        }
        Divider()
        Button("Delete", role: .destructive) {
            do {
                try storeManager.deleteFolder(id: folder.id)
            } catch {
                folderError = error.localizedDescription
            }
        }
    }

    /// Translate a `FolderPrompt` into the matching store mutation.
    /// Surfaces validation errors via the shared alert binding.
    private func applyFolderPrompt(_ prompt: FolderPrompt, name: String) {
        do {
            switch prompt.kind {
            case .createTopLevel:
                try storeManager.createFolder(name: name, in: nil)
            case .createSubfolder(let parent):
                try storeManager.createFolder(name: name, in: parent)
                expandedFolders[parent] = true  // open the parent so the new child is visible
            case .rename(let folderId, _):
                try storeManager.renameFolder(id: folderId, to: name)
            }
        } catch {
            folderError = error.localizedDescription
        }
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
        HStack(spacing: 6) {
            // Leading slot: spinner during connect, otherwise the
            // kind / favorite glyph. Sized to match Finder sidebar
            // icon density (~13pt with a 18pt fixed slot).
            ZStack {
                if isConnecting {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: rowGlyph)
                        .font(.system(size: 13))
                        .foregroundStyle(rowGlyphTint)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: 18)

            // Single-line — Finder rows are dense and rely on the
            // selection / details panel for secondary info. The full
            // `user@host:port` is on the row's tooltip, and the
            // selected profile's metadata always shows in the
            // Connection Details panel below.
            if isConnecting {
                Text("Connecting…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            } else {
                Text(profile.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        // Tighter vertical density to match Finder's ~24pt row
        // height. Two-line layouts pushed the rows closer to 36pt;
        // a one-line layout at this padding lands ~22pt visually.
        .padding(.vertical, 1)
        .opacity(isConnecting ? 0.7 : 1.0)
        .help("\(profile.username)@\(profile.host):\(profile.port)")
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
        if profile.favorite { return .yellow }
        // Match Finder's "folder = blue" cue for SFTP profiles since
        // they're file-only; SSH profiles read as a more neutral
        // greyed terminal glyph so the favourite + folder accents
        // stay visually distinct.
        switch profile.kind {
        case .ssh: return .secondary
        case .sftp: return .accentColor
        }
    }

    private var accessibilityLabel: String {
        let base = "\(profile.name), \(profile.username)@\(profile.host):\(profile.port)"
        return isConnecting ? "\(base), connecting" : base
    }
}

// MARK: - Section header

/// Finder-style section header: 11pt uppercase, semibold, secondary
/// color, kerned. SwiftUI's default `Section("Title")` renders mixed
/// case in a slightly larger font that reads more like a `List`
/// section than a sidebar one — replacing it gets the visual closer
/// to AppKit's NSOutlineView header style without resorting to a
/// hosted NSView.
private struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Folder row

/// Single folder header in the recursive sidebar. Distinct from
/// `ConnectionRow` because folders carry no live state (no connect
/// spinner, no host string), and using a separate view makes the
/// visual treatment easy to evolve without touching connection rows.
private struct FolderRow: View {
    let folder: ConnectionFolder

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 18)
            Text(folder.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Drag-drop transfer model

/// Wrapper that lets a `ConnectionProfile` ride a Swift drag session.
/// We can't use `ConnectionProfile` itself because uniffi-imported
/// codable structs have nested optionals that the Transferable system
/// chokes on; carrying just the id is enough — the receiver looks up
/// the live profile in the store.
///
/// Transfer is via a tagged-string `ProxyRepresentation` rather than
/// a custom UTType. UTType-based codable drags need the type
/// declared in Info.plist's UTExportedTypeDeclarations, which we
/// don't ship — without that, the drag silently fails to register
/// on macOS even though the code compiles. The "rshell-profile:"
/// prefix in the proxy string keeps the drop destination from
/// accidentally accepting plain text drags from elsewhere.
struct ProfileMove: Codable, Transferable {
    let profileId: String

    private static let prefix = "rshell-profile:"

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(
            exporting: { Self.prefix + $0.profileId },
            importing: { string in
                guard string.hasPrefix(Self.prefix) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return ProfileMove(
                    profileId: String(string.dropFirst(Self.prefix.count))
                )
            }
        )
    }
}

// MARK: - Folder name sheet

/// Tiny modal used for creating and renaming folders. Returns the
/// trimmed name through `onSubmit`; the caller decides whether to
/// route it to `createFolder` or `renameFolder`.
private struct FolderNameSheet: View {
    let title: String
    let initialName: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear { name = initialName }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        dismiss()
    }
}

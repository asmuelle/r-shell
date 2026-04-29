import AppKit
import SwiftUI
import OSLog

/// Single-pane remote file browser.
///
/// Calls `rshellSftpListDir` over the FFI for the active connection.
/// Path navigation is breadcrumb-style: clicking a directory drills in,
/// clicking an ancestor crumb walks back up. Right-click → Download
/// pushes a Transfer onto `TransferQueueStore`; the toolbar Upload
/// button opens an NSOpenPanel and enqueues an upload to the current
/// directory.
///
/// Errors (no connection, SFTP open failure, permission denied) surface
/// inline at the top of the list rather than via an alert; SFTP errors
/// are common enough that a modal interruption per directory is too
/// heavy.
struct FileBrowserView: View {
    /// Connection id from the active terminal tab. The view loads the
    /// initial listing on appear and whenever this changes.
    let connectionId: String?
    /// Display name for the connection (shown in the title row).
    let connectionLabel: String
    /// When non-nil, downloads land directly here without prompting
    /// via NSSavePanel. Used by the dual-pane SFTP layout to target
    /// the local pane's current cwd. The default `nil` keeps the
    /// existing single-pane behaviour: `~/Downloads` + a save panel
    /// per file.
    var downloadDirectory: String? = nil
    /// Fires whenever the user navigates to a new remote path. The
    /// dual-pane host uses this to mirror the cwd into the local
    /// pane's "Upload to Remote" target — without it, uploads
    /// triggered from the local pane would always land at the SFTP
    /// root regardless of where the user had drilled to on the
    /// remote side.
    var onPathChange: ((String) -> Void)? = nil

    @EnvironmentObject var transfers: TransferQueueStore

    @State private var path: String = "."
    @State private var entries: [FfiFileEntry] = []
    @State private var error: String?
    @State private var loading = false
    /// True while a Finder drag is hovering over the listing — drives a
    /// subtle accent-tinted overlay so the drop target is obvious.
    @State private var isDropTargeted = false
    /// When a drag hovers over a directory row, this holds the directory
    /// name so the row highlights and the drop lands inside that dir.
    @State private var dropTargetDir: String?

    /// Selected row ids (each row's `id` is its file name, unique
    /// within the directory). `Set` so the user can shift-/cmd-click
    /// multiple rows; the selection-aware context menu picks the
    /// single-vs-multi shape based on count.
    @State private var selection: Set<String> = []

    /// Column sort order. `kindOrder` first keeps directories grouped
    /// at the top regardless of the active sort key; the user-chosen
    /// column comes second. Tapping a column header rebinds the lead.
    @State private var sortOrder: [KeyPathComparator<FileRow>] = [
        KeyPathComparator(\.name)
    ]

    /// Sheet state for the New Folder / Rename text-input flows. Both
    /// share the same model — the action is what differs.
    @State private var inputSheet: InputSheet?

    /// Sheet state for the permissions/owner/group editor.
    @State private var permissionsEditorTarget: PermissionsEditorTarget?

    private struct PermissionsEditorTarget: Identifiable {
        let entry: FfiFileEntry
        let connectionId: String
        let remotePath: String
        var id: String { entry.name + remotePath }
    }

    private struct InputSheet: Identifiable {
        let id = UUID()
        let title: String
        let prompt: String
        let initialValue: String
        let confirmLabel: String
        let action: (String) -> Void
    }

    private let logger = Logger(subsystem: "com.r-shell", category: "file-browser")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let connectionId {
                listing(connectionId: connectionId)
            } else {
                noConnection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: connectionId) { _ in
            path = "."
            onPathChange?(".")
            refresh()
        }
        .onAppear { refresh() }
        .sheet(item: $inputSheet) { sheet in
            FileBrowserInputSheet(
                title: sheet.title,
                prompt: sheet.prompt,
                initialValue: sheet.initialValue,
                confirmLabel: sheet.confirmLabel,
                onConfirm: { value in
                    inputSheet = nil
                    sheet.action(value)
                },
                onCancel: { inputSheet = nil }
            )
        }
        .sheet(item: $permissionsEditorTarget) { target in
            FilePermissionsEditor(
                connectionId: target.connectionId,
                remotePath: target.remotePath,
                entryName: target.entry.name,
                currentPermissions: target.entry.permissions,
                currentOwner: target.entry.owner,
                currentGroup: target.entry.group,
                onDone: {
                    permissionsEditorTarget = nil
                    refresh()
                }
            )
            .frame(minWidth: 360, minHeight: 440)
        }
    }

    // MARK: - Header (title + breadcrumb)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(connectionLabel)
                    .font(.headline)
                Spacer()
                Button {
                    presentNewFolderPrompt()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(connectionId == nil)
                .help("Create a folder in the current directory")

                Button {
                    presentUploadPicker()
                } label: {
                    Label("Upload", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(connectionId == nil)
                .help("Upload a file to the current directory")

                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(connectionId == nil || loading)
                .help("Refresh")
            }

            breadcrumb
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button {
                navigateUp()
            } label: {
                Image(systemName: "arrow.turn.left.up")
            }
            .buttonStyle(.plain)
            .disabled(path == "." || path == "/")
            .help("Up one level")

            // Render the path as clickable segments. The first segment is
            // either `~` (when path is "." — the SFTP server's home) or `/`
            // (when the user has navigated to an absolute path).
            crumbSegments
        }
    }

    @ViewBuilder
    private var crumbSegments: some View {
        HStack(spacing: 4) {
            if path == "." {
                Text("~")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let segments = pathSegments(path)
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                    Button {
                        // Walk back to the prefix that ends with this segment.
                        let prefix = "/" + segments.prefix(idx + 1).joined(separator: "/")
                        navigate(to: prefix)
                    } label: {
                        Text(segment.isEmpty ? "/" : segment)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(idx == segments.count - 1 ? .primary : .secondary)
                    if idx < segments.count - 1 {
                        Text("/")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
    }

    private func pathSegments(_ path: String) -> [String] {
        // Strip the leading "/" so we get an array like ["", "usr", "local", "bin"]
        // — the empty first element represents the root.
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return [""] + trimmed.split(separator: "/").map(String.init)
    }

    // MARK: - Listing

    private func listing(connectionId: String) -> some View {
        Group {
            if let error {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileTable
            }
        }
    }

    /// SwiftUI `Table` with native column headers, click-to-sort, and
    /// multi-row selection. Each row's id is its file name (unique per
    /// directory). Double-click on a directory drills in; the
    /// selection-aware `.contextMenu(forSelectionType:)` adapts to the
    /// number of selected rows for batch actions.
    private var fileTable: some View {
        Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                nameCell(row)
            }

            TableColumn("Size", value: \.size) { row in
                Text(row.entry.kind == .directory ? "—" : formatSize(row.entry.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90, max: 140)

            TableColumn("Modified", value: \.modifiedSortKey) { row in
                Text(row.modifiedDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 140, max: 200)

            TableColumn("Permissions", value: \.permissions) { row in
                Text(row.entry.permissions ?? "—")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .width(min: 90, ideal: 110, max: 140)

            TableColumn("Owner", value: \.ownerGroup) { row in
                Text(row.ownerGroupDisplay)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 100, max: 160)
        }
        // Selection-aware context menu: shape adapts to single vs.
        // multi-row selection. Right-click on an unselected row puts
        // that row in `selectedIds` for the duration of the menu.
        .contextMenu(forSelectionType: String.self) { selectedIds in
            contextMenuContent(for: selectedIds)
        }
        // Return on a selected directory drills in. SwiftUI's
        // `.onSubmit(of: .table)` doesn't exist (only text/search), so
        // we attach a hidden keyboard-shortcut button: enabled only
        // when exactly one directory is selected, so Return is a
        // no-op everywhere else and doesn't shadow other handlers.
        .background(returnKeyShortcut)
        .dropDestination(for: URL.self) { urls, _ in
            acceptDrop(urls: urls)
        } isTargeted: { hovering in
            isDropTargeted = hovering
        }
        .overlay(alignment: .center) {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Row data wrapped from `FfiFileEntry` so it's `Identifiable +
    /// Hashable + Comparable`-keyable for the Table. Keeps directories
    /// grouped above files regardless of sort key by exposing
    /// `kindOrder` as a tie-breaker.
    fileprivate struct FileRow: Identifiable, Hashable {
        let entry: FfiFileEntry
        var id: String { entry.name }
        var name: String { entry.name }
        var size: UInt64 { entry.size }
        var permissions: String { entry.permissions ?? "" }
        /// Combined owner:group for sorting and display.
        var ownerGroup: String {
            let o = entry.owner ?? ""
            let g = entry.group ?? ""
            if o.isEmpty && g.isEmpty { return "" }
            return "\(o):\(g)"
        }
        var ownerGroupDisplay: String {
            let o = entry.owner ?? "—"
            let g = entry.group ?? "—"
            return "\(o):\(g)"
        }
        /// Raw Unix epoch seconds from the FFI. `0` (rather than nil)
        /// for missing timestamps so the column sort places undated
        /// entries together at one end consistently.
        var modifiedSortKey: Int64 { entry.modifiedUnix ?? 0 }
        /// Display string — locale-aware short date/time, falling back
        /// to "—" when no timestamp was provided.
        var modifiedDisplay: String {
            guard let secs = entry.modifiedUnix else { return "—" }
            let date = Date(timeIntervalSince1970: TimeInterval(secs))
            return Self.dateFormatter.string(from: date)
        }
        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            f.locale = Locale.current
            return f
        }()
        var kindOrder: Int {
            switch entry.kind {
            case .directory: return 0
            case .symlink:   return 1
            case .file:      return 2
            }
        }

        static func == (lhs: FileRow, rhs: FileRow) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Apply the user-chosen sort, then keep directories grouped above
    /// files via `kindOrder` as a stable secondary key.
    private var sortedRows: [FileRow] {
        let rows = entries.map(FileRow.init)
        return rows.sorted { lhs, rhs in
            if lhs.kindOrder != rhs.kindOrder { return lhs.kindOrder < rhs.kindOrder }
            return sortOrder.compare(lhs, rhs) == .orderedAscending
        }
    }

    /// Hidden Button that activates on Return. Enabled only when
    /// exactly one directory is selected — otherwise Return falls
    /// through to whichever control SwiftUI's responder chain picks
    /// (e.g. an input sheet's default Cancel button).
    @ViewBuilder
    private var returnKeyShortcut: some View {
        Button {
            guard selection.count == 1,
                  let id = selection.first,
                  let entry = entries.first(where: { $0.name == id }),
                  entry.kind == .directory
            else { return }
            navigate(into: entry.name)
        } label: { EmptyView() }
        .keyboardShortcut(.return, modifiers: [])
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(
            selection.count != 1
                || entries.first(where: { selection.contains($0.name) })?.kind != .directory
        )
    }

    @ViewBuilder
    private func contextMenuContent(for selectedIds: Set<String>) -> some View {
        switch selectedIds.count {
        case 0:
            // Empty-area right-click — only the directory-wide actions.
            Button("New Folder…") { presentNewFolderPrompt() }
            Button("Upload…") { presentUploadPicker() }

        case 1:
            // Single selection: show the existing file/dir actions.
            if let id = selectedIds.first, let entry = entries.first(where: { $0.name == id }) {
                if entry.kind == .file {
                    Button("Download…") { presentDownloadPicker(for: entry) }
                    Divider()
                }
                Button("Rename…") { presentRenamePrompt(for: entry) }
                Divider()
                Button("Edit Permissions…") {
                    guard let connId = connectionId else { return }
                    permissionsEditorTarget = PermissionsEditorTarget(
                        entry: entry,
                        connectionId: connId,
                        remotePath: absolutePath(joining: entry.name)
                    )
                }
                Divider()
                Button("Delete", role: .destructive) {
                    presentDeleteConfirmation(for: entry)
                }
            }

        default:
            // Multi-selection: batch actions only — single-row mutations
            // (rename) don't make sense, and download splits per file.
            Button("Download Selected (\(selectedIds.count))…") {
                downloadSelected(selectedIds)
            }
            Button("Delete Selected (\(selectedIds.count))…", role: .destructive) {
                deleteSelected(selectedIds)
            }
        }
    }

    private func rowIcon(_ kind: FfiFileKind) -> String {
        switch kind {
        case .directory: return "folder.fill"
        case .symlink:   return "link"
        case .file:      return "doc"
        }
    }

    private func rowIconTint(_ kind: FfiFileKind) -> Color {
        switch kind {
        case .directory: return .accentColor
        default:         return .secondary
        }
    }

    /// Name-column cell with per-row drop target for directories.
    /// Dropping files onto a folder row uploads into that folder
    /// instead of the current directory. File rows remain draggable
    /// (remote→local copy) but are not drop targets themselves.
    @ViewBuilder
    private func nameCell(_ row: FileRow) -> some View {
        let content = HStack(spacing: 8) {
            Image(systemName: rowIcon(row.entry.kind))
                .foregroundStyle(rowIconTint(row.entry.kind))
                .frame(width: 16)
            Text(row.entry.name)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if row.entry.kind == .directory {
                navigate(into: row.entry.name)
            }
        }

        if row.entry.kind == .directory {
            content
                .dropDestination(for: URL.self) { urls, _ in
                    acceptDrop(urls: urls, into: row.entry.name)
                } isTargeted: { hovering in
                    dropTargetDir = hovering ? row.entry.name : nil
                }
                .background(
                    dropTargetDir == row.entry.name
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            content
                .draggableIfPresent(remoteDragPayload(for: row))
        }
    }

    private func formatSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var noConnection: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Connect to a host from the sidebar to browse remote files.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Navigation

    private func navigate(into name: String) {
        let next: String
        if path == "." {
            // Don't know the absolute home yet; SFTP servers accept "name"
            // as a relative path from CWD, so just chain.
            next = name
        } else if path.hasSuffix("/") {
            next = path + name
        } else {
            next = path + "/" + name
        }
        navigate(to: next)
    }

    private func navigate(to newPath: String) {
        path = newPath
        onPathChange?(newPath)
        refresh()
    }

    /// Build a `RemoteFileDrag` payload for a row, or `nil` if the
    /// row isn't draggable (currently: directories, or a missing
    /// connection id). Pulled out so the call site stays readable
    /// and the directory exclusion is in one place.
    private func remoteDragPayload(for row: FileRow) -> RemoteFileDrag? {
        guard let connectionId else { return nil }
        guard row.entry.kind == .file else { return nil }
        return RemoteFileDrag(
            connectionId: connectionId,
            remotePath: absolutePath(joining: row.entry.name),
            name: row.entry.name,
            size: row.entry.size
        )
    }

    // MARK: - Transfers

    private func presentDownloadPicker(for entry: FfiFileEntry) {
        guard let connectionId else { return }
        let remotePath = absolutePath(joining: entry.name)

        // Dual-pane SFTP layout pre-supplies a target directory —
        // skip the save panel and drop the file straight in. Useful
        // for bulk transfers where one prompt per file would be
        // hostile.
        if let dir = downloadDirectory {
            let localURL = URL(fileURLWithPath: dir)
                .appendingPathComponent(entry.name)
            transfers.enqueueDownload(
                connectionId: connectionId,
                remotePath: remotePath,
                localPath: localURL.path,
                expectedSize: entry.size
            )
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Download \(entry.name)"
        savePanel.nameFieldStringValue = entry.name
        // Default to ~/Downloads — matches macOS standard behaviour.
        savePanel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first
        guard savePanel.runModal() == .OK, let localURL = savePanel.url else {
            return
        }
        transfers.enqueueDownload(
            connectionId: connectionId,
            remotePath: remotePath,
            localPath: localURL.path,
            expectedSize: entry.size
        )
    }

    /// Handle URLs dropped from Finder (or the local pane) onto the
    /// listing. When `into` is non-nil, uploads land inside that
    /// subdirectory of the current path. When `nil` (table-level
    /// drop), uploads go to the current directory.
    private func acceptDrop(urls: [URL], into dirName: String? = nil) -> Bool {
        guard let connectionId else { return false }
        var enqueued = 0

        for url in urls where url.isFileURL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            else {
                logger.info("Skipping non-existent drop: \(url.path, privacy: .public)")
                continue
            }

            let remoteFileName = url.lastPathComponent
            let remotePath: String
            if let dirName {
                remotePath = absolutePath(joining: "\(dirName)/\(remoteFileName)")
            } else {
                remotePath = absolutePath(joining: remoteFileName)
            }

            if isDir.boolValue {
                let connectionId = connectionId
                Task.detached {
                    await self.uploadDirectory(
                        connectionId: connectionId,
                        localRoot: url,
                        remoteRoot: remotePath
                    )
                }
                enqueued += 1
            } else {
                transfers.enqueueUpload(
                    connectionId: connectionId,
                    localPath: url.path,
                    remotePath: remotePath
                )
                enqueued += 1
            }
        }
        return enqueued > 0
    }

    /// Mirror a local directory tree onto the remote: mkdir each
    /// subdirectory in BFS order, then enqueue every file. mkdir is
    /// synchronous (one round trip per dir, fast); file uploads go
    /// through `TransferQueueStore` for progress / cancel UX.
    ///
    /// Errors mid-walk surface inline at the top of the listing —
    /// failed mkdirs stop their subtree, but other branches keep
    /// going so a single permission error doesn't cascade-fail the
    /// whole drop.
    private func uploadDirectory(
        connectionId: String,
        localRoot: URL,
        remoteRoot: String
    ) async {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: localRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            await MainActor.run { self.error = "Could not enumerate \(localRoot.lastPathComponent)" }
            return
        }

        // Make the root directory first.
        do {
            try rshellSftpCreateDir(connectionId: connectionId, path: remoteRoot)
        } catch let err as SftpError {
            // mkdir often fails with "already exists" — accept that
            // silently and proceed. Real errors (permission, no parent)
            // surface in the inline error banner.
            if case .Other(let detail) = err,
               !detail.lowercased().contains("exist") {
                await MainActor.run { self.error = "Could not create \(remoteRoot): \(detail)" }
                // Don't return — the upload-children loop below will
                // surface its own errors, but if the root mkdir failed
                // because it's a missing parent, those will be loud.
            }
        } catch {
            await MainActor.run { self.error = "Could not create \(remoteRoot): \(error.localizedDescription)" }
        }

        // Walk every entry. The enumerator yields files and directories
        // in some traversal order; we mkdir directories synchronously
        // (so a child file enqueue can rely on its parent existing) and
        // enqueue files via the transfer queue.
        for case let url as URL in enumerator {
            guard let resolved = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
                continue
            }
            let relativePath = url.path
                .replacingOccurrences(of: localRoot.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else { continue }

            let remoteChild = remoteRoot.hasSuffix("/")
                ? remoteRoot + relativePath
                : remoteRoot + "/" + relativePath

            if resolved.isDirectory == true {
                // Best-effort mkdir; ignore "already exists".
                _ = try? rshellSftpCreateDir(connectionId: connectionId, path: remoteChild)
            } else {
                await MainActor.run {
                    transfers.enqueueUpload(
                        connectionId: connectionId,
                        localPath: url.path,
                        remotePath: remoteChild
                    )
                }
            }
        }

        // The uploads are now queued; refresh the listing once on the
        // main actor so the new top-level directory shows up
        // immediately even before the per-file uploads finish.
        await MainActor.run { self.refresh() }
    }

    private func presentUploadPicker() {
        guard let connectionId else { return }
        let openPanel = NSOpenPanel()
        openPanel.title = "Upload to \(path == "." ? "~" : path)"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        guard openPanel.runModal() == .OK, let localURL = openPanel.url else {
            return
        }
        let filename = localURL.lastPathComponent
        let remotePath = absolutePath(joining: filename)
        transfers.enqueueUpload(
            connectionId: connectionId,
            localPath: localURL.path,
            remotePath: remotePath
        )
    }

    /// Build a remote path by joining the current `path` with a child
    /// name. Handles the home-shorthand case (`.`) by passing the bare
    /// name — SFTP servers resolve it relative to the user's home.
    private func absolutePath(joining name: String) -> String {
        if path == "." {
            return name
        }
        return path.hasSuffix("/") ? path + name : path + "/" + name
    }

    // MARK: - mkdir / rename / delete

    private func presentNewFolderPrompt() {
        guard let connectionId else { return }
        inputSheet = InputSheet(
            title: "New Folder",
            prompt: "Folder name",
            initialValue: "untitled folder",
            confirmLabel: "Create"
        ) { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
            let target = absolutePath(joining: trimmed)
            performSftp(action: "create folder") {
                try rshellSftpCreateDir(connectionId: connectionId, path: target)
            }
        }
    }

    private func presentRenamePrompt(for entry: FfiFileEntry) {
        guard let connectionId else { return }
        inputSheet = InputSheet(
            title: "Rename",
            prompt: "New name",
            initialValue: entry.name,
            confirmLabel: "Rename"
        ) { newName in
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != entry.name else { return }
            let oldPath = absolutePath(joining: entry.name)
            let newPath = absolutePath(joining: trimmed)
            performSftp(action: "rename") {
                try rshellSftpRename(
                    connectionId: connectionId,
                    oldPath: oldPath,
                    newPath: newPath
                )
            }
        }
    }

    private func presentDeleteConfirmation(for entry: FfiFileEntry) {
        guard let connectionId else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(entry.name)\"?"
        alert.informativeText = entry.kind == .directory
            ? "All contents will be removed recursively. This is permanent and cannot be undone."
            : "This is permanent and cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let target = absolutePath(joining: entry.name)
        performSftp(action: "delete") {
            switch entry.kind {
            case .directory:
                try Self.deleteRecursive(connectionId: connectionId, path: target)
            case .file, .symlink:
                try rshellSftpDeleteFile(connectionId: connectionId, path: target)
            }
        }
    }

    // MARK: - Multi-selection actions

    /// Batch download. NSOpenPanel-based directory chooser — each
    /// selected file lands inside that destination folder, named by
    /// its remote name. Reveal-in-Finder fires per transfer (so the
    /// user lands on whichever finished last); follow-up could batch
    /// these into one reveal of the destination directory.
    private func downloadSelected(_ ids: Set<String>) {
        guard let connectionId else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose download destination"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        for id in ids {
            guard let entry = entries.first(where: { $0.name == id }),
                  entry.kind == .file
            else { continue }
            let remotePath = absolutePath(joining: entry.name)
            let localURL = directory.appendingPathComponent(entry.name)
            transfers.enqueueDownload(
                connectionId: connectionId,
                remotePath: remotePath,
                localPath: localURL.path,
                expectedSize: entry.size
            )
        }
    }

    /// Batch delete: one confirmation dialog covering all selected
    /// rows, then delete each (recursively for directories) on a
    /// background task. Refreshes the listing once at the end.
    private func deleteSelected(_ ids: Set<String>) {
        guard let connectionId else { return }
        let names = entries
            .filter { ids.contains($0.name) }
            .map { $0.name }
        guard !names.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(names.count) item\(names.count == 1 ? "" : "s")?"
        alert.informativeText = names.prefix(5).joined(separator: ", ")
            + (names.count > 5 ? ", and \(names.count - 5) more" : "")
            + "\n\nDirectories are removed recursively. This is permanent."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let toDelete = entries.filter { ids.contains($0.name) }
        Task.detached {
            var failures: [String] = []
            for entry in toDelete {
                let target = await MainActor.run {
                    self.absolutePath(joining: entry.name)
                }
                do {
                    switch entry.kind {
                    case .directory:
                        try Self.deleteRecursive(connectionId: connectionId, path: target)
                    case .file, .symlink:
                        try rshellSftpDeleteFile(connectionId: connectionId, path: target)
                    }
                } catch {
                    failures.append("\(entry.name): \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                self.selection.removeAll()
                if !failures.isEmpty {
                    self.error = "Could not delete \(failures.count) item\(failures.count == 1 ? "" : "s"): "
                        + failures.prefix(3).joined(separator: "; ")
                }
                self.refresh()
            }
        }
    }

    /// Recursive delete: walk the directory contents, delete each
    /// child (subdirectories first via recursion), then delete the
    /// now-empty directory itself. Synchronous — runs on the
    /// background `Task.detached` that `performSftp` already uses.
    ///
    /// Each step is its own SFTP round-trip, so a deep tree is N+1
    /// requests where N is the descendant count. Acceptable for a
    /// single user-initiated delete; bulk operations would benefit
    /// from a server-side `rm -rf` over the SSH channel, but that's
    /// a larger UX shift (we'd lose the per-step error handling).
    private static func deleteRecursive(connectionId: String, path: String) throws {
        let entries = try rshellSftpListDir(connectionId: connectionId, path: path)
        for entry in entries {
            let childPath = path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name
            switch entry.kind {
            case .directory:
                try deleteRecursive(connectionId: connectionId, path: childPath)
            case .file, .symlink:
                try rshellSftpDeleteFile(connectionId: connectionId, path: childPath)
            }
        }
        try rshellSftpDeleteDir(connectionId: connectionId, path: path)
    }

    /// Run an SFTP mutation off the main actor, refresh on success,
    /// surface failures inline (rather than as a modal — every alert
    /// for a failed delete in a loop would be hostile).
    private func performSftp(action: String, _ work: @escaping () throws -> Void) {
        Task.detached {
            do {
                try work()
                await MainActor.run { self.refresh() }
            } catch let err as SftpError {
                await MainActor.run {
                    switch err {
                    case .NotConnected:
                        self.error = "Not connected to this host."
                    case .Cancelled:
                        // Mutations don't go through cancellation paths
                        // (they're one-shot SFTP commands), but the
                        // exhaustive switch needs the case.
                        self.error = "\(action.capitalized) cancelled."
                    case .Other(let detail):
                        self.error = "Could not \(action): \(detail)"
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = "Could not \(action): \(error.localizedDescription)"
                }
            }
        }
    }

    private func navigateUp() {
        guard path != "." && path != "/" else { return }
        if let lastSlash = path.lastIndex(of: "/") {
            let parent = String(path[..<lastSlash])
            path = parent.isEmpty ? "/" : parent
        } else {
            // Relative path with no slash — fall back to home.
            path = "."
        }
        refresh()
    }

    // MARK: - Loading

    private func refresh() {
        guard let connectionId else {
            entries = []
            error = nil
            return
        }
        loading = true
        error = nil

        let pathToList = path
        Task.detached {
            do {
                let result = try rshellSftpListDir(
                    connectionId: connectionId,
                    path: pathToList
                )
                await MainActor.run {
                    self.entries = result
                    self.loading = false
                }
            } catch let err as SftpError {
                await MainActor.run {
                    self.entries = []
                    self.loading = false
                    switch err {
                    case .NotConnected:
                        self.error = "Not connected to this host."
                    case .Cancelled:
                        // list_dir doesn't accept cancellation today,
                        // but kept for exhaustiveness if it does.
                        self.error = "Listing cancelled."
                    case .Other(let detail):
                        self.error = detail
                    }
                }
            } catch {
                await MainActor.run {
                    self.entries = []
                    self.loading = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Row

// MARK: - Text-input sheet (used for New Folder + Rename)

private struct FileBrowserInputSheet: View {
    let title: String
    let prompt: String
    let initialValue: String
    let confirmLabel: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var value: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { confirm() }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedValue.isEmpty || trimmedValue.contains("/"))
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            value = initialValue
            fieldFocused = true
        }
    }

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func confirm() {
        guard !trimmedValue.isEmpty, !trimmedValue.contains("/") else { return }
        onConfirm(trimmedValue)
    }
}

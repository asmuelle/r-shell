import AppKit
import SwiftUI
import OSLog

/// Single-pane remote file browser.
///
/// Calls typed bridge SFTP APIs for the active connection.
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
    /// Permission / owner / group edits currently run remote shell
    /// commands (`chmod`, `chown`, `chgrp`). SFTP-only accounts can
    /// browse files without shell access, so callers must disable this
    /// affordance when the active tab has no shell channel.
    var canEditPermissions: Bool = true
    /// Safe-save backups and validators execute shell commands on the
    /// remote host. SFTP-only accounts must keep inline editing on the
    /// SFTP path and skip those shell-only checks.
    var canRunRemoteCommands: Bool = true
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
    /// When a drag hovers over a directory row, this holds the directory
    /// name so the row highlights and the drop lands inside that dir.
    @State private var dropTargetDir: String?

    /// Selected row id (each row's `id` is its file name, unique
    /// within the directory). Keep this single-select: AppKit's
    /// multi-selection gestures compete with row dragging inside
    /// SwiftUI `Table` and can turn a drag into range selection.
    @State private var selection: String?

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
    /// Remote text file currently open in the built-in modal editor.
    @State private var editorTarget: EditorTarget?
    /// Remote path currently being fetched for the editor. Used to
    /// suppress duplicate opens and show a small row spinner.
    @State private var editorLoadingPath: String?

    private struct PermissionsEditorTarget: Identifiable {
        let entry: FfiFileEntry
        let connectionId: String
        let remotePath: String
        var id: String { entry.name + remotePath }
    }

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let connectionId: String
        let remotePath: String
        let fileName: String
        let content: String
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
    private static let maxInlineEditBytes: UInt64 = 1_048_576

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
        .sheet(item: $editorTarget, onDismiss: { refresh() }) { target in
            FileEditView(
                connectionId: target.connectionId,
                path: target.remotePath,
                content: target.content,
                canRunRemoteCommands: canRunRemoteCommands
            ) { updatedContent in
                try await saveEditedRemoteFile(updatedContent, target: target)
            }
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
            .frame(minHeight: 22)

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
            .disabled(path == "/")
            .help("Up one level")

            // Render the path as clickable segments. The first segment is
            // either `~` (relative to the SFTP server's login directory) or
            // `/` (when the user has navigated to an absolute path).
            crumbSegments
        }
    }

    @ViewBuilder
    private var crumbSegments: some View {
        HStack(spacing: 4) {
            if path.hasPrefix("/") {
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
            } else {
                let segments = relativePathSegments(path)
                if segments.isEmpty {
                    Text("~")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        navigate(to: ".")
                    } label: {
                        Text("~")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                        Text("/")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button {
                            navigate(to: relativePathPrefix(segments, through: idx))
                        } label: {
                            Text(segment)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(idx == segments.count - 1 ? .primary : .secondary)
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

    private func relativePathSegments(_ path: String) -> [String] {
        guard path != ".", !path.isEmpty else { return [] }
        return path.split(separator: "/").map(String.init)
    }

    private func relativePathPrefix(_ segments: [String], through index: Int) -> String {
        let prefix = segments.prefix(index + 1).joined(separator: "/")
        return prefix.isEmpty ? "." : prefix
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
    /// single-row selection. Each row's id is its file name (unique per
    /// directory). Double-click activates a row: directories drill in,
    /// editable text files open the modal editor. Row drags are handled
    /// from the name cell.
    private var fileTable: some View {
        Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                folderDropTarget(for: row) {
                    nameCell(row)
                }
            }

            TableColumn("Size", value: \.size) { row in
                folderDropTarget(for: row) {
                    Text(row.entry.kind == .directory ? "—" : formatSize(row.entry.size))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 90, max: 140)

            TableColumn("Modified", value: \.modifiedSortKey) { row in
                folderDropTarget(for: row) {
                    Text(row.modifiedDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 110, ideal: 140, max: 200)

            TableColumn("Permissions", value: \.permissions) { row in
                folderDropTarget(for: row) {
                    Text(row.entry.permissions ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 90, ideal: 110, max: 140)

            TableColumn("Owner", value: \.ownerGroup) { row in
                folderDropTarget(for: row) {
                    Text(row.ownerGroupDisplay)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .width(min: 70, ideal: 100, max: 160)
        }
        // Selection-aware context menu. Right-click on an unselected
        // row puts that row in `selectedIds` for the duration of the
        // menu.
        .contextMenu(forSelectionType: String.self) { selectedIds in
            contextMenuContent(for: selectedIds)
        }
        // Return on a selected directory drills in. SwiftUI's
        // `.onSubmit(of: .table)` doesn't exist (only text/search), so
        // we attach a hidden keyboard-shortcut button: enabled only
        // when exactly one directory is selected, so Return is a
        // no-op everywhere else and doesn't shadow other handlers.
        .background(returnKeyShortcut)
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
            guard let id = selection,
                  let entry = entries.first(where: { $0.name == id }),
                  entry.kind == .directory
            else { return }
            navigate(into: entry.name)
        } label: { EmptyView() }
        .keyboardShortcut(.return, modifiers: [])
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(selectedEntry?.kind != .directory)
    }

    private var selectedEntry: FfiFileEntry? {
        guard let selection else { return nil }
        return entries.first(where: { $0.name == selection })
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
                    if isInlineEditableFile(entry) {
                        Button("Open in Editor") { openEditor(for: entry) }
                    }
                    Button("Download…") { presentDownloadPicker(for: entry) }
                    Divider()
                }
                Button("Rename…") { presentRenamePrompt(for: entry) }
                if canEditPermissions {
                    Divider()
                    Button("Edit Permissions…") {
                        guard let connId = connectionId else { return }
                        permissionsEditorTarget = PermissionsEditorTarget(
                            entry: entry,
                            connectionId: connId,
                            remotePath: absolutePath(joining: entry.name)
                        )
                    }
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

    /// Make every cell in a folder row a local-file drop target.
    /// SwiftUI `Table` doesn't expose a row-level drop modifier, so
    /// applying the same target to each visible cell is the closest
    /// native equivalent: the whole folder row accepts the drop, while
    /// file rows and blank table space do not.
    @ViewBuilder
    private func folderDropTarget<Content: View>(
        for row: FileRow,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let cell = content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                activate(row.entry)
            }

        if row.entry.kind == .directory {
            cell
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
            cell
        }
    }

    /// Name-column cell. Rows are draggable for remote→local copy;
    /// directory rows are also upload targets via `folderDropTarget`.
    @ViewBuilder
    private func nameCell(_ row: FileRow) -> some View {
        let content = HStack(spacing: 8) {
            Image(systemName: rowIcon(row.entry.kind))
                .foregroundStyle(rowIconTint(row.entry.kind))
                .frame(width: 16)
            Text(row.entry.name)
                .lineLimit(1)
            if editorLoadingPath == absolutePath(joining: row.entry.name) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
            }
        }
        .contentShape(Rectangle())

        content
            .dragProviderIfPresent(remoteDragPayload(for: row)?.itemProvider)
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

    private func activate(_ entry: FfiFileEntry) {
        selection = entry.name
        if entry.kind == .directory {
            navigate(into: entry.name)
        } else if isInlineEditableFile(entry) {
            openEditor(for: entry)
        }
    }

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
        let normalizedPath = newPath.isEmpty ? "." : newPath
        path = normalizedPath
        onPathChange?(normalizedPath)
        refresh()
    }

    /// Build a `RemoteFileDrag` payload for a row, or `nil` if the
    /// row isn't draggable (currently: only a missing connection id).
    /// Pulled out so the call site stays readable.
    private func remoteDragPayload(for row: FileRow) -> RemoteFileDrag? {
        guard let connectionId else { return nil }
        let kind: RemoteFileDrag.Kind
        switch row.entry.kind {
        case .file:
            kind = .file
        case .directory:
            kind = .directory
        case .symlink:
            kind = .symlink
        }
        return RemoteFileDrag(
            connectionId: connectionId,
            remotePath: absolutePath(joining: row.entry.name),
            name: row.entry.name,
            size: row.entry.size,
            kind: kind
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

    /// Handle URLs dropped from Finder or the local pane onto a
    /// remote folder row. Uploads land inside that subdirectory of
    /// the current remote path.
    private func acceptDrop(urls: [URL], into dirName: String) -> Bool {
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
            let remotePath = absolutePath(joining: "\(dirName)/\(remoteFileName)")

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
    /// subdirectory in BFS order, then enqueue every file. Directory
    /// creation is awaited one path at a time; file uploads go through
    /// `TransferQueueStore` for progress / cancel UX.
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
            try await BridgeManager.shared.sftpCreateDir(connectionId: connectionId, path: remoteRoot)
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

        var discoveredURLs: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            discoveredURLs.append(url)
        }

        // Walk every entry. The enumerator yields files and directories
        // in some traversal order; we mkdir directories synchronously
        // (so a child file enqueue can rely on its parent existing) and
        // enqueue files via the transfer queue.
        for url in discoveredURLs {
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
                try? await BridgeManager.shared.sftpCreateDir(connectionId: connectionId, path: remoteChild)
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

    // MARK: - Inline editor

    private func isInlineEditableFile(_ entry: FfiFileEntry) -> Bool {
        guard entry.kind == .file else { return false }
        if entry.name.hasPrefix("."), entry.name != ".", entry.name != ".." {
            return true
        }

        switch (entry.name as NSString).pathExtension.lowercased() {
        case "yaml", "yml", "txt", "sh", "sql", "service":
            return true
        default:
            return false
        }
    }

    private func openEditor(for entry: FfiFileEntry) {
        guard let connectionId, isInlineEditableFile(entry) else { return }
        let remotePath = absolutePath(joining: entry.name)
        guard editorLoadingPath != remotePath else { return }

        selection = entry.name
        editorLoadingPath = remotePath
        error = nil

        Task {
            do {
                let content = try await loadRemoteTextFile(
                    connectionId: connectionId,
                    remotePath: remotePath,
                    expectedSize: entry.size
                )
                await MainActor.run {
                    editorLoadingPath = nil
                    editorTarget = EditorTarget(
                        connectionId: connectionId,
                        remotePath: remotePath,
                        fileName: entry.name,
                        content: content
                    )
                }
            } catch {
                await MainActor.run {
                    editorLoadingPath = nil
                    self.error = "Could not open \(entry.name): \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadRemoteTextFile(
        connectionId: String,
        remotePath: String,
        expectedSize: UInt64
    ) async throws -> String {
        let fileName = (remotePath as NSString).lastPathComponent
        if expectedSize > Self.maxInlineEditBytes {
            throw RemoteTextFileEditError.fileTooLarge(fileName: fileName, size: expectedSize)
        }

        let tempURL = temporaryEditorURL(for: remotePath)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = try await BridgeManager.shared.sftpDownload(
            transferId: UUID(),
            connectionId: connectionId,
            remotePath: remotePath,
            localPath: tempURL.path,
            expectedSize: expectedSize
        )

        let data = try Data(contentsOf: tempURL)
        if UInt64(data.count) > Self.maxInlineEditBytes {
            throw RemoteTextFileEditError.fileTooLarge(fileName: fileName, size: UInt64(data.count))
        }
        if let content = String(data: data, encoding: .utf8) {
            return content
        }
        if let content = String(data: data, encoding: .ascii) {
            return content
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    private func saveEditedRemoteFile(
        _ content: String,
        target: EditorTarget
    ) async throws {
        let tempURL = temporaryEditorURL(for: target.remotePath)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let data = content.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: tempURL, options: .atomic)

        _ = try await BridgeManager.shared.sftpUpload(
            transferId: UUID(),
            connectionId: target.connectionId,
            localPath: tempURL.path,
            remotePath: target.remotePath
        )
    }

    private func temporaryEditorURL(for remotePath: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("midnight-ssh-editor", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let pathExtension = (remotePath as NSString).pathExtension
        let fileName = pathExtension.isEmpty
            ? UUID().uuidString
            : "\(UUID().uuidString).\(pathExtension)"
        return directory.appendingPathComponent(fileName)
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
                try await BridgeManager.shared.sftpCreateDir(connectionId: connectionId, path: target)
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
                try await BridgeManager.shared.sftpRename(
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
                try await Self.deleteRecursive(connectionId: connectionId, path: target)
            case .file, .symlink:
                try await BridgeManager.shared.sftpDeleteFile(connectionId: connectionId, path: target)
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
        Task {
            var failures: [String] = []
            for entry in toDelete {
                let target = self.absolutePath(joining: entry.name)
                do {
                    switch entry.kind {
                    case .directory:
                        try await Self.deleteRecursive(connectionId: connectionId, path: target)
                    case .file, .symlink:
                        try await BridgeManager.shared.sftpDeleteFile(connectionId: connectionId, path: target)
                    }
                } catch {
                    failures.append("\(entry.name): \(error.localizedDescription)")
                }
            }
            self.selection = nil
            if !failures.isEmpty {
                self.error = "Could not delete \(failures.count) item\(failures.count == 1 ? "" : "s"): "
                    + failures.prefix(3).joined(separator: "; ")
            }
            self.refresh()
        }
    }

    /// Recursive delete: walk the directory contents, delete each
    /// child (subdirectories first via recursion), then delete the
    /// now-empty directory itself.
    ///
    /// Each step is its own SFTP round-trip, so a deep tree is N+1
    /// requests where N is the descendant count. Acceptable for a
    /// single user-initiated delete; bulk operations would benefit
    /// from a server-side `rm -rf` over the SSH channel, but that's
    /// a larger UX shift (we'd lose the per-step error handling).
    private static func deleteRecursive(connectionId: String, path: String) async throws {
        let entries = try await BridgeManager.shared.sftpListDir(connectionId: connectionId, path: path)
        for entry in entries {
            let childPath = path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name
            switch entry.kind {
            case .directory:
                try await deleteRecursive(connectionId: connectionId, path: childPath)
            case .file, .symlink:
                try await BridgeManager.shared.sftpDeleteFile(connectionId: connectionId, path: childPath)
            }
        }
        try await BridgeManager.shared.sftpDeleteDir(connectionId: connectionId, path: path)
    }

    /// Run an SFTP mutation through the bridge, refresh on success,
    /// surface failures inline (rather than as a modal — every alert
    /// for a failed delete in a loop would be hostile).
    private func performSftp(action: String, _ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                self.refresh()
            } catch let err as SftpError {
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
            } catch {
                self.error = "Could not \(action): \(error.localizedDescription)"
            }
        }
    }

    private func navigateUp() {
        guard path != "/" else { return }
        navigate(to: parentPath(for: path))
    }

    private func parentPath(for currentPath: String) -> String {
        if currentPath == "." {
            return ".."
        }

        if currentPath.hasPrefix("/") {
            guard let lastSlash = currentPath.lastIndex(of: "/") else { return "/" }
            let parent = String(currentPath[..<lastSlash])
            return parent.isEmpty ? "/" : parent
        }

        let segments = relativePathSegments(currentPath)
        guard !segments.isEmpty else { return ".." }
        if segments.allSatisfy({ $0 == ".." }) {
            return (segments + [".."]).joined(separator: "/")
        }
        guard segments.count > 1 else { return "." }
        return segments.dropLast().joined(separator: "/")
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
        Task {
            do {
                let result = try await BridgeManager.shared.sftpListDir(
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

private enum RemoteTextFileEditError: LocalizedError {
    case fileTooLarge(fileName: String, size: UInt64)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let fileName, let size):
            let clampedSize = min(size, UInt64(Int64.max))
            let formattedSize = ByteCountFormatter.string(
                fromByteCount: Int64(clampedSize),
                countStyle: .file
            )
            return "\(fileName) is too large to edit safely (\(formattedSize))."
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

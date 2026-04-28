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

    @EnvironmentObject var transfers: TransferQueueStore

    @State private var path: String = "."
    @State private var entries: [FfiFileEntry] = []
    @State private var error: String?
    @State private var loading = false

    /// Sheet state for the New Folder / Rename text-input flows. Both
    /// share the same model — the action is what differs.
    @State private var inputSheet: InputSheet?

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
        // Render the path as clickable segments. The first segment is
        // either `~` (when path is "." — the SFTP server's home) or `/`
        // (when the user has navigated to an absolute path).
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
                List {
                    if path != "." && path != "/" {
                        Button {
                            navigateUp()
                        } label: {
                            Label("..", systemImage: "arrow.turn.left.up")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(entries, id: \.name) { entry in
                        FileEntryRow(
                            entry: entry,
                            onActivate: {
                                if entry.kind == .directory {
                                    navigate(into: entry.name)
                                }
                            },
                            onDownload: entry.kind == .file
                                ? { presentDownloadPicker(for: entry) }
                                : nil,
                            onRename: { presentRenamePrompt(for: entry) },
                            onDelete: { presentDeleteConfirmation(for: entry) }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var noConnection: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Open a terminal session, then switch to Files to browse.")
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
        refresh()
    }

    // MARK: - Transfers

    private func presentDownloadPicker(for entry: FfiFileEntry) {
        guard let connectionId else { return }
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
        let remotePath = absolutePath(joining: entry.name)
        transfers.enqueueDownload(
            connectionId: connectionId,
            remotePath: remotePath,
            localPath: localURL.path,
            expectedSize: entry.size
        )
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
            ? "Directories must be empty. The deletion is permanent and cannot be undone."
            : "This is permanent and cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let target = absolutePath(joining: entry.name)
        performSftp(action: "delete") {
            switch entry.kind {
            case .directory:
                try rshellSftpDeleteDir(connectionId: connectionId, path: target)
            case .file, .symlink:
                try rshellSftpDeleteFile(connectionId: connectionId, path: target)
            }
        }
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

private struct FileEntryRow: View {
    let entry: FfiFileEntry
    let onActivate: () -> Void
    /// Non-nil only for plain files. Triggers an NSSavePanel-driven
    /// download via the row's context menu.
    let onDownload: (() -> Void)?
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconTint)
                    .frame(width: 16)

                Text(entry.name)
                    .lineLimit(1)

                Spacer()

                if let modified = entry.modified {
                    Text(modified)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if entry.kind != .directory {
                    Text(formatSize(entry.size))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onDownload {
                Button("Download…", action: onDownload)
                Divider()
            }
            Button("Rename…", action: onRename)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var icon: String {
        switch entry.kind {
        case .directory: return "folder.fill"
        case .symlink:   return "link"
        case .file:      return "doc"
        }
    }

    private var iconTint: Color {
        switch entry.kind {
        case .directory: return .accentColor
        case .symlink:   return .secondary
        case .file:      return .secondary
        }
    }

    private func formatSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

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

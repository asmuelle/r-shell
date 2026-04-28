import SwiftUI
import OSLog
import RShellMacOS

/// Dual-pane file browser with local (left) and remote (right) views.
///
/// Layout:
///   ┌─────────────┬─────────────┐
///   │ Local Files │Remote Files │
///   │ ...         │ ...         │
///   │ path/foo    │ /home/...   │
///   │ bar.txt     │ bar.txt ◄───│ drag to upload
///   │ baz/        │ baz/        │
///   └─────────────┴─────────────┘
///   │ Transfer Queue: [===   ]  │
///   └───────────────────────────┘
struct FileBrowserPanel: View {
    let connectionId: String
    let remoteTitle: String

    @StateObject private var fileOps = FileOperationsManager.shared
    @StateObject private var transferQueue = TransferQueueManager.shared
    @State private var state = FileBrowserState.initial
    @State private var editFile: EditFileRequest?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var sortBy: SortKey = .name
    @State private var searchQuery = ""

    enum SortKey: String, CaseIterable {
        case name, size, date
    }

    var body: some View {
        HSplitView {
            // Local pane
            filePane(
                title: "Local",
                path: $state.localPath,
                files: filteredLocal,
                selection: $state.selectedLocal,
                isRemote: false
            )

            // Remote pane
            filePane(
                title: remoteTitle,
                path: $state.remotePath,
                files: filteredRemote,
                selection: $state.selectedRemote,
                isRemote: true
            )
        }
        .frame(minWidth: 600, minHeight: 300)
        .task { await refreshLocal() }
        .task { await refreshRemote() }
        .sheet(isPresented: $showNewFolder) {
            VStack(spacing: 12) {
                Text("New Folder").font(.headline)
                TextField("Folder name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showNewFolder = false }
                    Button("Create") {
                        createFolder()
                        showNewFolder = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 300)
        }
        .sheet(item: $editFile) { req in
            FileEditView(
                connectionId: req.connectionId,
                path: req.path,
                content: req.content,
                onSave: { newContent in
                    Task { await fileOps.saveRemoteFile(connectionId: req.connectionId, path: req.path, content: newContent) }
                }
            )
        }
    }

    // MARK: - Pane builder

    private func filePane(title: String, path: Binding<String>, files: [FileEntry], selection: Binding<Set<String>>, isRemote: Bool) -> some View {
        VStack(spacing: 0) {
            // Path bar
            HStack {
                Text(title).font(.caption).foregroundColor(.secondary)
                TextField("Path", text: path)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                Button("Go") {
                    Task { await isRemote ? refreshRemote() : refreshLocal() }
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // File list
            List(files, id: \.id, selection: selection) { entry in
                FileRow(entry: entry, isRemote: isRemote)
                    .tag(entry.id)
                    .onDoubleClick {
                        if entry.type == .directory {
                            if isRemote {
                                state.remotePath = entry.path
                                Task { await refreshRemote() }
                            } else {
                                state.localPath = entry.path
                                Task { await refreshLocal() }
                            }
                        } else if isRemote {
                            editFile = EditFileRequest(connectionId: connectionId, path: entry.path, content: "")
                        }
                    }
                    .contextMenu { fileContextMenu(entry: entry, isRemote: isRemote) }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func fileContextMenu(entry: FileEntry, isRemote: Bool) -> some View {
        if !isRemote {
            Button("Open in Finder") { fileOps.openInFinder(path: entry.path) }
            Button("Reveal in Finder") { fileOps.revealInFinder(path: entry.path) }
        }

        Button(entry.type == .directory ? "Download" : "Upload") {
            if isRemote {
                transferQueue.enqueueDownload(connectionId: connectionId, remotePath: entry.path, localPath: localDownloadPath(entry))
            } else {
                transferQueue.enqueueUpload(connectionId: connectionId, localPath: entry.path, remotePath: "\(state.remotePath)/\(entry.name)")
            }
        }

        Divider()
        Button("Rename…") { /* prompt rename */ }
        Button("Delete", role: .destructive) {
            if !isRemote {
                _ = fileOps.deleteLocalItem(path: entry.path)
                Task { await refreshLocal() }
            }
        }
    }

    // MARK: - Helpers

    private var filteredLocal: [FileEntry] {
        let f = state.localFiles
        if searchQuery.isEmpty { return sorted(f) }
        return sorted(f.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) })
    }

    private var filteredRemote: [FileEntry] {
        let f = state.remoteFiles
        if searchQuery.isEmpty { return sorted(f) }
        return sorted(f.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) })
    }

    private func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if a.type == .directory && b.type != .directory { return true }
            if a.type != .directory && b.type == .directory { return false }
            switch sortBy {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: return a.size > b.size
            case .date: return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            }
        }
    }

    private func localDownloadPath(_ entry: FileEntry) -> String {
        let home = NSHomeDirectory() + "/Downloads"
        return "\(home)/\(entry.name)"
    }

    private func createFolder() {
        let path = "\(state.remotePath)/\(newFolderName)"
        Task {
            await fileOps.createRemoteDirectory(connectionId: connectionId, path: path)
            await refreshRemote()
        }
    }

    private func refreshLocal() async {
        state.localFiles = await fileOps.listLocalFiles(path: state.localPath)
    }

    private func refreshRemote() async {
        state.isLoading = true
        state.remoteFiles = await fileOps.listRemoteFiles(connectionId: connectionId, path: state.remotePath)
        state.isLoading = false
    }
}

// MARK: - File row view

struct FileRow: View {
    let entry: FileEntry
    let isRemote: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .frame(width: 16)

            Text(entry.name)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer()

            if entry.type == .file {
                Text(formatFileSize(entry.size))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Text(formatTimestamp(entry.modified))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }

    private var iconName: String {
        switch entry.type {
        case .directory: return "folder"
        case .symlink: return "link"
        case .file:
            if entry.name.hasSuffix(".swift") || entry.name.hasSuffix(".rs") || entry.name.hasSuffix(".py") { return "doc.text" }
            if entry.name.hasSuffix(".png") || entry.name.hasSuffix(".jpg") { return "photo" }
            return "doc"
        }
    }

    private var iconColor: Color {
        switch entry.type {
        case .directory: return .blue
        case .symlink: return .purple
        case .file: return .secondary
        }
    }
}

// MARK: - Double-click modifier

struct DoubleClickModifier: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.onTapGesture(count: 2, perform: action)
    }
}

extension View {
    func onDoubleClick(perform action: @escaping () -> Void) -> some View {
        modifier(DoubleClickModifier(action: action))
    }
}

// MARK: - Edit file request

struct EditFileRequest: Identifiable {
    var id: String { path }
    var connectionId: String
    var path: String
    var content: String
}

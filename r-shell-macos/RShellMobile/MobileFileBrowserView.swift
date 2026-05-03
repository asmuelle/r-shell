import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MobileFileBrowserView: View {
    let connectionId: String
    let profileName: String

    @State private var path = "."
    @State private var entries: [FfiFileEntry] = []
    @State private var selectedName: String?
    @State private var isLoading = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var editorDocument: MobileRemoteFileDocument?
    @State private var loadingEditorPath: String?
    @State private var namePrompt: MobileFileNamePrompt?
    @State private var deleteTarget: MobileRemoteFileRow?
    @State private var showingImporter = false
    @State private var exportItem: MobileFileExport?

    private var rows: [MobileRemoteFileRow] {
        entries
            .sorted { lhs, rhs in
                if lhs.kind == .directory, rhs.kind != .directory { return true }
                if lhs.kind != .directory, rhs.kind == .directory { return false }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { entry in
                MobileRemoteFileRow(
                    remotePath: absolutePath(joining: entry.name),
                    entry: entry
                )
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            pathBar

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            fileList
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: connectionId) {
            await refresh()
        }
        .sheet(item: $editorDocument) { document in
            MobileRemoteFileEditorView(
                document: document,
                onSave: { content in
                    try await MobileSFTPBridge.shared.saveRemoteTextFile(
                        connectionId: document.connectionId,
                        remotePath: document.remotePath,
                        fileName: document.fileName,
                        content: content
                    )
                },
                onSaved: {
                    statusMessage = "Saved \(document.fileName)."
                    Task { await refresh() }
                }
            )
        }
        .sheet(item: $namePrompt) { prompt in
            MobileFileNamePromptSheet(
                prompt: prompt,
                onCancel: { namePrompt = nil },
                onCommit: { value in
                    namePrompt = nil
                    prompt.onCommit(value)
                }
            )
            .presentationDetents([.height(190)])
        }
        .sheet(item: $exportItem) { item in
            MobileShareSheet(url: item.url)
        }
        .confirmationDialog(
            "Delete item?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let deleteTarget else { return }
                self.deleteTarget = nil
                delete(row: deleteTarget)
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            if deleteTarget?.entry.kind == .directory {
                Text("Directories are removed recursively. This cannot be undone.")
            } else {
                Text("This cannot be undone.")
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                upload(urls: urls)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Files", systemImage: "folder")
                    .font(.headline)
                Text(profileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLoading || isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                navigateUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(path == "." || path == "/" || isLoading)
            .accessibilityLabel("Up")

            Text(displayPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
            .accessibilityLabel("Refresh")

            Button {
                presentNewFolderPrompt()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .disabled(isWorking)
            .accessibilityLabel("New folder")

            Button {
                showingImporter = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(isWorking)
            .accessibilityLabel("Upload")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var fileList: some View {
        if rows.isEmpty, !isLoading {
            ContentUnavailableView(
                "No Files",
                systemImage: "folder",
                description: Text("This remote directory is empty.")
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            List(rows) { row in
                rowView(row)
                    .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                    .listRowBackground(
                        selectedName == row.entry.name
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
            }
            .listStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 420)
            .refreshable {
                await refresh()
            }
        }
    }

    private func rowView(_ row: MobileRemoteFileRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: row.entry.kind))
                .foregroundStyle(iconTint(for: row.entry.kind))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.entry.name)
                        .font(.body)
                        .lineLimit(1)

                    if loadingEditorPath == row.remotePath {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text(rowSubtitle(row.entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if row.entry.kind == .file, isEditableFile(row.entry) {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedName = row.entry.name
        }
        .onTapGesture(count: 2) {
            activate(row)
        }
        .contextMenu {
            contextMenu(for: row)
        }
    }

    @ViewBuilder
    private func contextMenu(for row: MobileRemoteFileRow) -> some View {
        if row.entry.kind == .directory {
            Button("Open") { navigate(into: row.entry.name) }
        } else if isEditableFile(row.entry) {
            Button("Open in Editor") { openEditor(row) }
        }

        if row.entry.kind == .file {
            Button("Download") { download(row) }
        }

        Button("Rename") { presentRenamePrompt(for: row) }
        Button("Delete", role: .destructive) { deleteTarget = row }
    }

    private var displayPath: String {
        path == "." ? "~" : path
    }

    private func rowSubtitle(_ entry: FfiFileEntry) -> String {
        let size = entry.kind == .directory
            ? "Directory"
            : ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
        let permissions = entry.permissions ?? "---"
        if let modified = entry.modified, !modified.isEmpty {
            return "\(size) - \(permissions) - \(modified)"
        }
        return "\(size) - \(permissions)"
    }

    private func iconName(for kind: FfiFileKind) -> String {
        switch kind {
        case .directory:
            return "folder.fill"
        case .symlink:
            return "link"
        case .file:
            return "doc"
        }
    }

    private func iconTint(for kind: FfiFileKind) -> Color {
        switch kind {
        case .directory:
            return .blue
        case .symlink:
            return .purple
        case .file:
            return .secondary
        }
    }

    private func activate(_ row: MobileRemoteFileRow) {
        selectedName = row.entry.name
        switch row.entry.kind {
        case .directory:
            navigate(into: row.entry.name)
        case .file:
            if isEditableFile(row.entry) {
                openEditor(row)
            } else {
                download(row)
            }
        case .symlink:
            selectedName = row.entry.name
        }
    }

    private func navigate(into name: String) {
        path = absolutePath(joining: name)
        selectedName = nil
        Task { await refresh() }
    }

    private func navigateUp() {
        guard path != "." && path != "/" else { return }

        if let lastSlash = path.lastIndex(of: "/") {
            let parent = String(path[..<lastSlash])
            path = parent.isEmpty ? "/" : parent
        } else {
            path = "."
        }

        selectedName = nil
        Task { await refresh() }
    }

    private func absolutePath(joining name: String) -> String {
        if path == "." {
            return name
        }
        return path.hasSuffix("/") ? path + name : path + "/" + name
    }

    private func isEditableFile(_ entry: FfiFileEntry) -> Bool {
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

    private func openEditor(_ row: MobileRemoteFileRow) {
        guard isEditableFile(row.entry) else { return }
        guard row.entry.size <= 1_048_576 else {
            errorMessage = MobileSFTPBridgeError
                .fileTooLarge(fileName: row.entry.name, size: row.entry.size)
                .localizedDescription
            return
        }

        selectedName = row.entry.name
        loadingEditorPath = row.remotePath
        errorMessage = nil

        Task {
            do {
                let content = try await MobileSFTPBridge.shared.readRemoteTextFile(
                    connectionId: connectionId,
                    remotePath: row.remotePath,
                    fileName: row.entry.name,
                    expectedSize: row.entry.size
                )
                await MainActor.run {
                    loadingEditorPath = nil
                    editorDocument = MobileRemoteFileDocument(
                        connectionId: connectionId,
                        remotePath: row.remotePath,
                        fileName: row.entry.name,
                        initialContent: content
                    )
                }
            } catch {
                await MainActor.run {
                    loadingEditorPath = nil
                    errorMessage = "Could not open \(row.entry.name): \(describe(error))"
                }
            }
        }
    }

    private func download(_ row: MobileRemoteFileRow) {
        guard row.entry.kind == .file else { return }
        selectedName = row.entry.name
        isWorking = true
        errorMessage = nil
        statusMessage = nil

        Task {
            do {
                let url = try await MobileSFTPBridge.shared.downloadForExport(
                    connectionId: connectionId,
                    remotePath: row.remotePath,
                    fileName: row.entry.name,
                    expectedSize: row.entry.size
                )
                await MainActor.run {
                    isWorking = false
                    exportItem = MobileFileExport(url: url)
                    statusMessage = "Downloaded \(row.entry.name)."
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = "Could not download \(row.entry.name): \(describe(error))"
                }
            }
        }
    }

    private func upload(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = nil

        let targetPath = path
        Task {
            var uploaded = 0
            var failures: [String] = []

            for url in urls {
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                    guard values.isDirectory != true else {
                        failures.append("\(url.lastPathComponent): directory upload is not in the mobile MVP yet")
                        continue
                    }

                    let remotePath = join(path: targetPath, child: url.lastPathComponent)
                    _ = try await MobileSFTPBridge.shared.upload(
                        connectionId: connectionId,
                        localPath: url.path,
                        remotePath: remotePath
                    )
                    uploaded += 1
                } catch {
                    failures.append("\(url.lastPathComponent): \(describe(error))")
                }
            }

            await MainActor.run {
                isWorking = false
                if !failures.isEmpty {
                    errorMessage = "Upload finished with \(failures.count) failure\(failures.count == 1 ? "" : "s"): "
                        + failures.prefix(2).joined(separator: "; ")
                } else {
                    statusMessage = "Uploaded \(uploaded) file\(uploaded == 1 ? "" : "s")."
                }
                Task { await refresh() }
            }
        }
    }

    private func presentNewFolderPrompt() {
        namePrompt = MobileFileNamePrompt(
            title: "New Folder",
            prompt: "Folder name",
            initialValue: "untitled folder",
            confirmLabel: "Create"
        ) { value in
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validateRemoteName(name) else { return }
            mutate(action: "create folder") {
                try await MobileSFTPBridge.shared.createDir(
                    connectionId: connectionId,
                    path: absolutePath(joining: name)
                )
            }
        }
    }

    private func presentRenamePrompt(for row: MobileRemoteFileRow) {
        namePrompt = MobileFileNamePrompt(
            title: "Rename",
            prompt: "New name",
            initialValue: row.entry.name,
            confirmLabel: "Rename"
        ) { value in
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validateRemoteName(name), name != row.entry.name else { return }
            mutate(action: "rename") {
                try await MobileSFTPBridge.shared.rename(
                    connectionId: connectionId,
                    oldPath: row.remotePath,
                    newPath: absolutePath(joining: name)
                )
            }
        }
    }

    private func delete(row: MobileRemoteFileRow) {
        mutate(action: "delete") {
            switch row.entry.kind {
            case .directory:
                try await Self.deleteRecursive(connectionId: connectionId, path: row.remotePath)
            case .file, .symlink:
                try await MobileSFTPBridge.shared.deleteFile(
                    connectionId: connectionId,
                    path: row.remotePath
                )
            }
        }
    }

    private func mutate(action: String, work: @escaping () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        statusMessage = nil

        Task {
            do {
                try await work()
                await MainActor.run {
                    isWorking = false
                    statusMessage = "\(action.capitalized) complete."
                    Task { await refresh() }
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = "Could not \(action): \(describe(error))"
                }
            }
        }
    }

    private static func deleteRecursive(connectionId: String, path: String) async throws {
        let entries = try await MobileSFTPBridge.shared.listDir(connectionId: connectionId, path: path)
        for entry in entries {
            let childPath = join(path: path, child: entry.name)
            switch entry.kind {
            case .directory:
                try await deleteRecursive(connectionId: connectionId, path: childPath)
            case .file, .symlink:
                try await MobileSFTPBridge.shared.deleteFile(connectionId: connectionId, path: childPath)
            }
        }
        try await MobileSFTPBridge.shared.deleteDir(connectionId: connectionId, path: path)
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil
        let requestedPath = path

        do {
            let result = try await MobileSFTPBridge.shared.listDir(
                connectionId: connectionId,
                path: requestedPath
            )
            guard path == requestedPath else { return }
            entries = result
            isLoading = false
        } catch {
            guard path == requestedPath else { return }
            entries = []
            isLoading = false
            errorMessage = describe(error)
        }
    }

    private func validateRemoteName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/") else {
            errorMessage = MobileSFTPBridgeError.invalidRemoteName(name).localizedDescription
            return false
        }
        return true
    }

    private func describe(_ error: Error) -> String {
        if let sftpError = error as? SftpError {
            switch sftpError {
            case .NotConnected:
                return "Not connected to this host."
            case .Cancelled:
                return "Cancelled."
            case .Other(let detail):
                return detail
            }
        }
        return error.localizedDescription
    }
}

private func join(path: String, child: String) -> String {
    if path == "." {
        return child
    }
    return path.hasSuffix("/") ? path + child : path + "/" + child
}

private struct MobileRemoteFileRow: Identifiable, Hashable {
    let remotePath: String
    let entry: FfiFileEntry

    var id: String {
        remotePath
    }
}

private struct MobileFileNamePrompt: Identifiable {
    let id = UUID()
    let title: String
    let prompt: String
    let initialValue: String
    let confirmLabel: String
    let onCommit: (String) -> Void
}

private struct MobileFileNamePromptSheet: View {
    let prompt: MobileFileNamePrompt
    let onCancel: () -> Void
    let onCommit: (String) -> Void

    @State private var value: String
    @FocusState private var focused: Bool

    init(
        prompt: MobileFileNamePrompt,
        onCancel: @escaping () -> Void,
        onCommit: @escaping (String) -> Void
    ) {
        self.prompt = prompt
        self.onCancel = onCancel
        self.onCommit = onCommit
        _value = State(initialValue: prompt.initialValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(prompt.prompt) {
                    TextField("", text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit { commit() }
                }
            }
            .navigationTitle(prompt.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(prompt.confirmLabel, action: commit)
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                focused = true
            }
        }
    }

    private func commit() {
        onCommit(value)
    }
}

private struct MobileFileExport: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MobileShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

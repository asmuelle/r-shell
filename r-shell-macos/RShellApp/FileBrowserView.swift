import SwiftUI
import OSLog

/// Single-pane remote file browser MVP.
///
/// Calls `rshellSftpListDir` over the FFI for the active connection.
/// Path navigation is breadcrumb-style: clicking a directory drills in,
/// clicking an ancestor crumb walks back up. No transfers in this slice
/// — upload / download / delete / rename land in the next pass.
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

    @State private var path: String = "."
    @State private var entries: [FfiFileEntry] = []
    @State private var error: String?
    @State private var loading = false

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
                        FileEntryRow(entry: entry) {
                            if entry.kind == .directory {
                                navigate(into: entry.name)
                            }
                        }
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

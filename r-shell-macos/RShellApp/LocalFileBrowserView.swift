import AppKit
import SwiftUI
import OSLog
import UniformTypeIdentifiers

/// Transferable wrapper for a remote (SFTP) file dragged out of
/// `FileBrowserView`. Carries everything the receiver needs to
/// schedule a download via `TransferQueueStore` without re-stating
/// the SFTP listing — `connectionId` resolves the session, and
/// `remotePath` is the absolute remote path so the receiver doesn't
/// need to know about the remote pane's cwd.
///
/// Custom UTType so the drag can't accidentally be accepted by
/// Finder, the system pasteboard, or any other sidebar drop target.
struct RemoteFileDrag: Codable, Transferable {
    let connectionId: String
    let remotePath: String
    let name: String
    let size: UInt64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .rshellRemoteFile)
    }
}

extension UTType {
    static let rshellRemoteFile = UTType(exportedAs: "com.r-shell.remote-file")
}

/// Folder reparent payload. Carries just the folder id; the receiver
/// looks up the live folder + does the move via
/// `ConnectionStoreManager.moveFolder`. Custom UTType for the same
/// reason `ProfileMove` has its own — keeps the drag from being
/// silently accepted by Finder or other system surfaces.
struct FolderMove: Codable, Transferable {
    let folderId: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .rshellFolderMove)
    }
}

extension UTType {
    static let rshellFolderMove = UTType(exportedAs: "com.r-shell.folder-move")
}

extension View {
    /// Apply `.draggable` only when a payload is supplied. Lets call
    /// sites express "directories aren't draggable" as the absence
    /// of a payload (`nil`) rather than wrapping the modifier chain
    /// in a `Group { if … }` that breaks `some View` inference.
    @ViewBuilder
    func draggableIfPresent<T: Transferable>(_ payload: T?) -> some View {
        if let payload {
            self.draggable(payload)
        } else {
            self
        }
    }
}

/// Single-pane local file browser, used as the right side of the
/// Midnight-Commander layout for SFTP-only profiles.
///
/// Mirrors `FileBrowserView`'s shape (header + breadcrumb + sortable
/// Table + context menu) but runs against `FileManager` instead of
/// the SFTP FFI. No network in the loop, so listings refresh
/// synchronously on the main thread.
///
/// Cross-pane copy hooks: each row is `.draggable` with its file URL,
/// so a drag onto the remote pane's listing reuses
/// `FileBrowserView.acceptDrop` and uploads. The reverse direction
/// (remote → local) is handled by the remote pane's "Download here"
/// context-menu item, which the dual-pane host wires up with the
/// local path as the target.
struct LocalFileBrowserView: View {
    @Binding var path: String
    let onUploadToRemote: ((URL) -> Void)?
    /// Triggered when a `RemoteFileDrag` is dropped on this pane.
    /// The host wires this to a download into the local pane's
    /// current cwd. Optional so the single-pane case (when this
    /// view ever gets reused outside the dual-pane host) doesn't
    /// have to plumb a closure it can't satisfy.
    let onDownloadFromRemote: ((RemoteFileDrag) -> Void)?

    @State private var entries: [LocalFileEntry] = []
    @State private var selection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<LocalFileEntry>] = [
        KeyPathComparator(\.name)
    ]
    @State private var error: String?
    /// `true` while a remote-file drag is hovering over the pane —
    /// drives the same accent-tinted overlay the remote pane uses
    /// for Finder drops.
    @State private var isDropTargeted = false

    private let logger = Logger(subsystem: "com.r-shell", category: "local-file-browser")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refresh() }
        .onChange(of: path) { _ in refresh() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                Text("Local")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    revealInFinder(URL(fileURLWithPath: path))
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            breadcrumb
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var breadcrumb: some View {
        let crumbs = breadcrumbCrumbs
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { idx, crumb in
                    Button(crumb.label) {
                        path = crumb.path
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(idx == crumbs.count - 1 ? Color.primary : Color.secondary)
                    if idx < crumbs.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.caption)
        }
    }

    /// Convert the current path into a list of (label, full-path)
    /// breadcrumbs. Includes the user's home as a friendly "~"
    /// shortcut so a deep path doesn't push the actual filename
    /// off-screen on a narrow pane.
    private var breadcrumbCrumbs: [(label: String, path: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var components: [(String, String)] = []
        let normalized: String
        if path.hasPrefix(home) {
            normalized = "~" + String(path.dropFirst(home.count))
        } else {
            normalized = path
        }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        var accumulated = ""
        var realAccumulated = normalized.hasPrefix("/") ? "" : home
        for (idx, segment) in parts.enumerated() {
            if segment.isEmpty && idx == 0 {
                accumulated = "/"
                components.append(("/", "/"))
                continue
            }
            if segment == "~" {
                components.append(("Home", home))
                realAccumulated = home
                continue
            }
            if segment.isEmpty { continue }
            accumulated = accumulated.isEmpty ? String(segment) : "\(accumulated)/\(segment)"
            realAccumulated = realAccumulated.isEmpty
                ? "/\(segment)"
                : "\(realAccumulated)/\(segment)"
            components.append((String(segment), realAccumulated))
        }
        return components
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            table
        }
    }

    private var table: some View {
        let rows = entries.sorted(using: sortOrder)
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : iconFor(entry.url))
                        .foregroundStyle(entry.isDirectory
                            ? AnyShapeStyle(.tint)
                            : AnyShapeStyle(.secondary))
                        .frame(width: 14)
                    Text(entry.name)
                        .lineLimit(1)
                }
                // Per-row draggable so the remote pane's existing
                // `URL` drop destination accepts our files unchanged.
                // Directories also drag — the remote pane already
                // walks them recursively in `acceptDrop`.
                .draggable(entry.url)
            }

            TableColumn("Size", value: \.size) { entry in
                Text(entry.isDirectory ? "—" : ByteCountFormatter.string(
                    fromByteCount: entry.size,
                    countStyle: .file
                ))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Modified", value: \.modifiedUnix) { entry in
                Text(entry.modifiedDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 130)
        }
        .contextMenu(forSelectionType: String.self) { selectedNames in
            contextMenu(for: selectedNames, rows: rows)
        } primaryAction: { selected in
            // Double-click: drill into a directory or open the file.
            if selected.count == 1, let name = selected.first,
               let row = rows.first(where: { $0.name == name }) {
                openRow(row)
            }
        }
        // Drop target for remote files. The receiver hands back the
        // `RemoteFileDrag` payload; the host turns it into a queued
        // download into this pane's current cwd. Hover state drives
        // the same accent border the remote pane uses for Finder
        // drops, so the cross-pane direction reads consistently.
        .dropDestination(for: RemoteFileDrag.self) { drops, _ in
            guard let onDownloadFromRemote else { return false }
            for drop in drops { onDownloadFromRemote(drop) }
            return !drops.isEmpty
        } isTargeted: { hovering in
            isDropTargeted = hovering
        }
        .overlay(alignment: .center) {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for selectedNames: Set<String>, rows: [LocalFileEntry]) -> some View {
        let chosen = rows.filter { selectedNames.contains($0.name) }
        if chosen.count == 1, let row = chosen.first {
            if row.isDirectory {
                Button("Open") { path = row.url.path }
            } else {
                Button("Open with Default App") {
                    NSWorkspace.shared.open(row.url)
                }
            }
            Button("Reveal in Finder") { revealInFinder(row.url) }
            Divider()
            if !row.isDirectory, let onUploadToRemote {
                Button("Upload to Remote") { onUploadToRemote(row.url) }
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                trash(urls: [row.url])
            }
        } else if chosen.count > 1 {
            // Bulk: only support upload + trash.
            if let onUploadToRemote {
                let files = chosen.filter { !$0.isDirectory }
                Button("Upload \(files.count) Files to Remote") {
                    for f in files { onUploadToRemote(f.url) }
                }
                .disabled(files.isEmpty)
                Divider()
            }
            Button("Move to Trash", role: .destructive) {
                trash(urls: chosen.map(\.url))
            }
        }
    }

    // MARK: - Actions

    private func openRow(_ row: LocalFileEntry) {
        if row.isDirectory {
            path = row.url.path
        } else {
            NSWorkspace.shared.open(row.url)
        }
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func trash(urls: [URL]) {
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                logger.error("Trash failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        refresh()
    }

    /// Reload `entries` from `path`. Bubbles up the FileManager error
    /// (permission denied, missing path) into the view's error
    /// placeholder rather than alerting — local-file errors are
    /// almost always "I don't have permission to read `~/Library`"
    /// and an alert per attempt would be hostile.
    private func refresh() {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles]
            )
            entries = urls.compactMap { LocalFileEntry(url: $0) }
            error = nil
        } catch let err {
            entries = []
            error = err.localizedDescription
        }
    }

    /// Best-effort SF Symbol lookup for the file icon. Doesn't pretend
    /// to be exhaustive — only the buckets users encounter most often
    /// while browsing for an upload target. Everything else falls back
    /// to a generic doc glyph.
    private func iconFor(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "txt", "md", "log": return "doc.text"
        case "json", "yaml", "yml", "toml", "xml": return "doc.badge.gearshape"
        case "swift", "rs", "py", "js", "ts", "go", "c", "cpp", "h": return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "mp3", "wav", "aac", "m4a", "flac": return "waveform"
        case "zip", "tar", "gz", "bz2", "xz", "7z": return "archivebox"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}

// MARK: - Local file model

struct LocalFileEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let size: Int64
    let isDirectory: Bool
    let modifiedUnix: Int64
    var id: String { name }

    var modifiedDisplay: String {
        guard modifiedUnix > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(modifiedUnix))
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]) else { return nil }

        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = values.isDirectory ?? false
        self.size = Int64(values.fileSize ?? 0)
        self.modifiedUnix = values.contentModificationDate.map {
            Int64($0.timeIntervalSince1970)
        } ?? 0
    }
}

import AppKit
import SwiftUI
import OSLog
import UniformTypeIdentifiers
import Darwin

/// Pasteboard payload for a remote (SFTP) file dragged out of
/// `FileBrowserView`. Carries everything the receiver needs to
/// schedule a download via `TransferQueueStore` without re-stating
/// the SFTP listing: `connectionId` resolves the session, and
/// `remotePath` is the absolute remote path so the receiver doesn't
/// need to know about the remote pane's cwd.
///
/// Transfer uses a tagged-string proxy rather than a custom UTType.
/// UTType-backed Codable drags need an exported type declaration in
/// Info.plist to reliably register on macOS; without it, SwiftUI can
/// start the drag but matching drop destinations never receive it.
/// The prefix keeps this from being accepted as generic text.
struct RemoteFileDrag: Codable {
    enum Kind: String, Codable {
        case file
        case directory
        case symlink
    }

    let connectionId: String
    let remotePath: String
    let name: String
    let size: UInt64
    let kind: Kind

    var isDirectory: Bool { kind == .directory }

    private static let prefix = "rshell-remote-file:"

    var pasteboardString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return Self.prefix + data.base64EncodedString()
    }

    var itemProvider: NSItemProvider? {
        guard let pasteboardString else { return nil }
        return NSItemProvider(object: pasteboardString as NSString)
    }

    static func decodePasteboardString(_ string: String) -> RemoteFileDrag? {
        guard string.hasPrefix(prefix),
              let data = Data(base64Encoded: String(string.dropFirst(prefix.count)))
        else { return nil }
        return try? JSONDecoder().decode(RemoteFileDrag.self, from: data)
    }
}

/// Folder reparent payload. Carries just the folder id; the receiver
/// looks up the live folder + does the move via
/// `ConnectionStoreManager.moveFolder`. Same `ProxyRepresentation`
/// pattern as `ProfileMove` — UTType-based codable drags need the
/// type declared in Info.plist's UTExportedTypeDeclarations to
/// register on macOS, which we don't ship.
struct FolderMove: Codable, Transferable {
    let folderId: String

    private static let prefix = "rshell-folder:"

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(
            exporting: { Self.prefix + $0.folderId },
            importing: { string in
                guard string.hasPrefix(Self.prefix) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return FolderMove(
                    folderId: String(string.dropFirst(Self.prefix.count))
                )
            }
        )
    }
}

extension View {
    /// Apply `.onDrag` only when a provider is supplied. Lets call
    /// sites express "this row is not draggable" as `nil` without
    /// breaking `some View` inference.
    @ViewBuilder
    func dragProviderIfPresent(_ provider: NSItemProvider?) -> some View {
        if let provider {
            self.onDrag { provider }
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
/// (remote → local) accepts `RemoteFileDrag` payloads from the remote
/// pane and lets the dual-pane host queue a download into this pane's
/// current path.
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
    @State private var selection: String?
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
        .modifier(PathChangeRefresh(path: path, refresh: refresh))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                Text("Local")
                    .font(.headline)
                Spacer()
                Button {
                    revealInFinder(URL(fileURLWithPath: path))
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            // Match the remote pane's bordered/small control row so the
            // two headers line up; otherwise the plain icon buttons here
            // collapse to a shorter row and the panes look misaligned.
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
            .disabled(isAtRoot)
            .help("Up one level")

            ScrollView(.horizontal, showsIndicators: false) {
                let crumbs = breadcrumbCrumbs
                HStack(spacing: 4) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { idx, crumb in
                        Button(crumb.label) {
                            path = crumb.path
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(idx == crumbs.count - 1 ? Color.primary : Color.secondary)
                        if idx < crumbs.count - 1 {
                            Text("/")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    /// `true` when the current path has no parent directory (the
    /// filesystem root). Used to disable the "Up" button so it doesn't
    /// silently no-op.
    private var isAtRoot: Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized == "/" || standardized.isEmpty
    }

    private func navigateUp() {
        let parent = URL(fileURLWithPath: path)
            .standardizedFileURL
            .deletingLastPathComponent()
            .path
        guard !parent.isEmpty, parent != path else { return }
        path = parent
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
                tapTarget(for: entry) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : iconFor(entry.url))
                            .foregroundStyle(entry.isDirectory
                                ? AnyShapeStyle(.tint)
                                : AnyShapeStyle(.secondary))
                            .frame(width: 14)
                        Text(entry.name)
                            .lineLimit(1)
                    }
                }
                // Per-row draggable so the remote pane's existing
                // `URL` drop destination accepts our files unchanged.
                // Directories also drag — the remote pane already
                // walks them recursively in `acceptDrop`.
                .draggable(entry.url)
            }

            TableColumn("Size", value: \.size) { entry in
                tapTarget(for: entry) {
                    Text(entry.isDirectory ? "—" : ByteCountFormatter.string(
                        fromByteCount: entry.size,
                        countStyle: .file
                    ))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 80)

            TableColumn("Modified", value: \.modifiedUnix) { entry in
                tapTarget(for: entry) {
                    Text(entry.modifiedDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 90, ideal: 130)

            TableColumn("Owner", value: \.owner) { entry in
                tapTarget(for: entry) {
                    Text("\(entry.owner):\(entry.group)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .width(min: 70, ideal: 100, max: 160)
        }
        .contextMenu(forSelectionType: String.self) { selectedNames in
            contextMenu(for: selectedNames, rows: rows)
        }
        // Drop target for remote files. The receiver hands back the
        // `RemoteFileDrag` payload; the host turns it into a queued
        // download into this pane's current cwd. Hover state drives
        // the same accent border the remote pane uses for Finder
        // drops, so the cross-pane direction reads consistently.
        .onDrop(of: [UTType.plainText], isTargeted: $isDropTargeted) { providers in
            acceptRemoteDrops(providers)
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

    /// Wrap a cell so the entire row width is hit-testable and a
    /// double-click drills into the row. Mirrors `FileBrowserView`'s
    /// `folderDropTarget` shape so the two panes feel identical —
    /// `Table.primaryAction:` is unreliable when paired with a
    /// single-row optional selection binding, so we wire the gesture
    /// per-cell instead.
    @ViewBuilder
    private func tapTarget<Content: View>(
        for entry: LocalFileEntry,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { openRow(entry) }
    }

    private func acceptRemoteDrops(_ providers: [NSItemProvider]) -> Bool {
        guard let onDownloadFromRemote else { return false }

        let remoteProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }
        guard !remoteProviders.isEmpty else { return false }

        for provider in remoteProviders {
            provider.loadItem(
                forTypeIdentifier: UTType.plainText.identifier,
                options: nil
            ) { item, _ in
                let raw: String?
                if let string = item as? String {
                    raw = string
                } else if let string = item as? NSString {
                    raw = string as String
                } else if let data = item as? Data {
                    raw = String(data: data, encoding: .utf8)
                } else {
                    raw = nil
                }

                guard let raw,
                      let drop = RemoteFileDrag.decodePasteboardString(raw)
                else { return }

                DispatchQueue.main.async {
                    onDownloadFromRemote(drop)
                }
            }
        }

        return true
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

/// Bridges the macOS 13 single-parameter `onChange` and the macOS 14
/// zero-parameter form. The deployment target is still 13.0, but
/// SourceKit flags the legacy signature as deprecated; the availability
/// branch keeps both surfaces happy without an `@available`-stamped view.
private struct PathChangeRefresh: ViewModifier {
    let path: String
    let refresh: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            content.onChange(of: path) { refresh() }
        } else {
            content.onChange(of: path) { _ in refresh() }
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
    let owner: String
    let group: String
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

        var st = stat()
        if stat(url.path, &st) == 0 {
            self.owner = String(st.st_uid)
            self.group = String(st.st_gid)
        } else {
            self.owner = "—"
            self.group = "—"
        }
    }
}

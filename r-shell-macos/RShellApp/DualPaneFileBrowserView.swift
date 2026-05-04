import SwiftUI

/// Midnight-Commander-style two-pane layout used in place of the
/// terminal + monitor stack when the active connection is SFTP-only.
///
///   ┌─────────────────────┬─────────────────────┐
///   │                     │                     │
///   │  Remote (SFTP)      │  Local (FileMgr)    │
///   │                     │                     │
///   └─────────────────────┴─────────────────────┘
///
/// Each pane navigates independently. Cross-pane copy works in two
/// ways:
///
/// 1. Local → Remote: the local pane offers an "Upload to Remote"
///    context-menu action that hands the URL back to this view via
///    the `onUploadToRemote` closure; we forward it through the
///    `TransferQueueStore` to the active SFTP session, just like
///    Finder drag-drops onto the remote pane already do.
/// 2. Remote → Local: the remote pane exports `RemoteFileDrag`
///    payloads; dropping one on the local pane queues a download into
///    the local pane's current cwd so users don't have to round-trip
///    through `~/Downloads`.
struct DualPaneFileBrowserView: View {
    let connectionId: String?
    let connectionLabel: String
    /// SSH tabs have a real shell channel so remote permissions edits
    /// (chmod/chown/chgrp) and safe-save backups work; SFTP-only tabs
    /// must leave these off. Defaults match the original SFTP-only
    /// caller so existing usages stay unchanged.
    var canEditPermissions: Bool = false
    var canRunRemoteCommands: Bool = false

    @EnvironmentObject var transfers: TransferQueueStore

    /// Local pane cwd. Default to the user's home; deeply-nested
    /// `~/Library` etc. is a less useful starting point and the user
    /// can navigate down with one or two clicks.
    @State private var localPath: String = FileManager.default
        .homeDirectoryForCurrentUser.path
    /// Remote pane cwd, kept in lock-step with the SFTP browser via
    /// its `onPathChange` callback. The local pane reads this when
    /// queuing an upload so files land where the user is looking,
    /// not at the SFTP root.
    @State private var remotePath: String = "."
    @State private var transferError: String?

    var body: some View {
        HSplitView {
            FileBrowserView(
                connectionId: connectionId,
                connectionLabel: connectionLabel,
                downloadDirectory: localPath,
                canEditPermissions: canEditPermissions,
                canRunRemoteCommands: canRunRemoteCommands,
                onPathChange: { remotePath = $0 }
            )
            .frame(minWidth: 280)

            LocalFileBrowserView(
                path: $localPath,
                onUploadToRemote: connectionId == nil
                    ? nil
                    : { url in uploadLocalFile(url) },
                onDownloadFromRemote: { drop in
                    enqueueDownload(drop)
                }
            )
            .frame(minWidth: 280)
        }
        .overlay {
            TransferProgressOverlay()
                .environmentObject(transfers)
        }
        .alert(
            "Transfer failed",
            isPresented: Binding(
                get: { transferError != nil },
                set: { if !$0 { transferError = nil } }
            )
        ) {
            Button("OK") { transferError = nil }
        } message: {
            Text(transferError ?? "")
        }
    }

    /// Push a local URL onto the transfer queue as an upload to the
    /// remote pane's current dir. This is used by the local pane's
    /// context-menu action; drag-and-drop uploads are handled by
    /// dropping directly onto a remote folder row. The file basename is
    /// appended to whatever cwd the user has drilled into. `"."`
    /// (the initial value) tells the SFTP server to use the session
    /// root, so a fresh connect that uploads before any navigation
    /// still lands somewhere sensible.
    private func uploadLocalFile(_ url: URL) {
        guard let connectionId else { return }
        let name = url.lastPathComponent
        let remote: String
        if remotePath == "." || remotePath.isEmpty {
            remote = name
        } else if remotePath.hasSuffix("/") {
            remote = remotePath + name
        } else {
            remote = remotePath + "/" + name
        }
        transfers.enqueueUpload(
            connectionId: connectionId,
            localPath: url.path,
            remotePath: remote
        )
    }

    /// Schedule a download triggered by dragging a remote row onto
    /// the local pane. The `RemoteFileDrag` already carries the
    /// absolute remote path; we just join the basename onto the
    /// local pane's cwd to know where to write.
    private func enqueueDownload(_ drop: RemoteFileDrag) {
        let localURL = URL(fileURLWithPath: localPath)
            .appendingPathComponent(drop.name)
        if drop.isDirectory {
            Task {
                await enqueueDirectoryDownload(drop, localRoot: localURL)
            }
            return
        }

        transfers.enqueueDownload(
            connectionId: drop.connectionId,
            remotePath: drop.remotePath,
            localPath: localURL.path,
            expectedSize: drop.size
        )
    }

    private func enqueueDirectoryDownload(_ drop: RemoteFileDrag, localRoot: URL) async {
        do {
            try await createLocalDirectory(localRoot)
            try await enqueueRemoteDirectoryContents(
                connectionId: drop.connectionId,
                remoteRoot: drop.remotePath,
                localRoot: localRoot
            )
        } catch {
            transferError = "Could not download \(drop.name): \(error.localizedDescription)"
        }
    }

    private func enqueueRemoteDirectoryContents(
        connectionId: String,
        remoteRoot: String,
        localRoot: URL
    ) async throws {
        let entries = try await BridgeManager.shared.sftpListDir(connectionId: connectionId, path: remoteRoot)

        for entry in entries {
            let remoteChild = joinRemotePath(remoteRoot, entry.name)
            let localChild = localRoot.appendingPathComponent(entry.name)

            switch entry.kind {
            case .directory:
                try await createLocalDirectory(localChild)
                try await enqueueRemoteDirectoryContents(
                    connectionId: connectionId,
                    remoteRoot: remoteChild,
                    localRoot: localChild
                )
            case .file, .symlink:
                await MainActor.run {
                    transfers.enqueueDownload(
                        connectionId: connectionId,
                        remotePath: remoteChild,
                        localPath: localChild.path,
                        expectedSize: entry.size
                    )
                }
            }
        }
    }

    private func createLocalDirectory(_ url: URL) async throws {
        try await Task.detached {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }.value
    }

    private func joinRemotePath(_ base: String, _ name: String) -> String {
        if base == "." || base.isEmpty {
            return name
        }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }
}

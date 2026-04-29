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
/// 2. Remote → Local: handled by the existing `FileBrowserView`
///    Download flow; we surface the local pane's current cwd as the
///    download destination so users don't have to round-trip through
///    `~/Downloads`.
struct DualPaneFileBrowserView: View {
    let connectionId: String?
    let connectionLabel: String

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

    var body: some View {
        HSplitView {
            FileBrowserView(
                connectionId: connectionId,
                connectionLabel: connectionLabel,
                downloadDirectory: localPath,
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
    }

    /// Push a local URL onto the transfer queue as an upload to the
    /// remote pane's current dir. Path composition mirrors the
    /// remote pane's `acceptDrop` policy: the file basename is
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
        transfers.enqueueDownload(
            connectionId: drop.connectionId,
            remotePath: drop.remotePath,
            localPath: localURL.path,
            expectedSize: drop.size
        )
    }
}

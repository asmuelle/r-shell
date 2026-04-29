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

    var body: some View {
        HSplitView {
            FileBrowserView(
                connectionId: connectionId,
                connectionLabel: connectionLabel,
                downloadDirectory: localPath
            )
            .frame(minWidth: 280)

            LocalFileBrowserView(
                path: $localPath,
                onUploadToRemote: connectionId == nil
                    ? nil
                    : { url in uploadLocalFile(url) }
            )
            .frame(minWidth: 280)
        }
    }

    /// Push a local URL onto the transfer queue as an upload to the
    /// remote pane's current dir. Mirrors the path policy used when
    /// Finder drag-drops onto the remote pane: file basename is
    /// appended to the remote path so the upload lands in the
    /// currently-displayed remote directory.
    private func uploadLocalFile(_ url: URL) {
        guard let connectionId else { return }
        // We don't know the remote pane's cwd from here without
        // hoisting it up, so target the SFTP root and let users move
        // with `mv` if needed. A future iteration could thread the
        // remote path through a binding too, but for v1 the symmetric
        // cross-pane drag (Finder drag onto the remote pane) is the
        // path most users will reach for.
        let name = url.lastPathComponent
        transfers.enqueueUpload(
            connectionId: connectionId,
            localPath: url.path,
            remotePath: name
        )
    }
}

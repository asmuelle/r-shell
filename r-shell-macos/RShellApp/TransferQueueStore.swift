import AppKit
import Foundation
import OSLog

/// Owns the list of in-flight and completed SFTP transfers. The
/// `BottomPanel` renders this; the `FileBrowserView` enqueues from
/// download / upload actions.
///
/// Architecture: each enqueue spawns a `Task.detached` that calls the
/// FFI synchronously (the Rust side blocks on its Tokio runtime). The
/// FFI emits `TransferProgress` events on every chunk; we observe them
/// via NotificationCenter and update the matching `Transfer` by
/// `(connectionId, remotePath)` — the same tuple Rust stamps onto each
/// event. The Task awaits completion, then sets the transfer's final
/// state.
///
/// **Concurrency cap:** transfers are run sequentially per connection
/// (the SFTP subsystem on a single SSH session can't multiplex). Cross-
/// connection transfers run concurrently. Tracking lives in
/// `runningPerConnection`.
@MainActor
final class TransferQueueStore: ObservableObject {
    @Published private(set) var transfers: [Transfer] = []

    private let logger = Logger(subsystem: "com.r-shell", category: "transfers")
    private var observer: NSObjectProtocol?
    /// Per-connection serial pump. Each connection has its own `Task`
    /// chain so transfers to host A don't block transfers to host B.
    private var runningPerConnection: [String: Task<Void, Never>] = [:]

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .rshellTransferProgress,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let info = note.userInfo,
                      let connectionId = info["connectionId"] as? String,
                      let payload = info["payload"] as? String
                else { return }
                self.handleProgress(connectionId: connectionId, payload: payload)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Enqueue

    func enqueueDownload(
        connectionId: String,
        remotePath: String,
        localPath: String,
        expectedSize: UInt64
    ) {
        let transfer = Transfer(
            id: UUID(),
            connectionId: connectionId,
            kind: .download,
            remotePath: remotePath,
            localPath: localPath,
            totalBytes: expectedSize,
            bytesTransferred: 0,
            status: .queued
        )
        transfers.append(transfer)
        scheduleRun(for: connectionId)
    }

    func enqueueUpload(
        connectionId: String,
        localPath: String,
        remotePath: String
    ) {
        // Stat client-side so the queue UI can show a total even before
        // the first progress event arrives. Falls back to 0 (indeterminate
        // progress bar) if the file's gone or unreadable — the FFI will
        // surface the real error on the actual upload attempt.
        let totalBytes: UInt64 = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
                  let size = attrs[.size] as? NSNumber else { return 0 }
            return size.uint64Value
        }()

        let transfer = Transfer(
            id: UUID(),
            connectionId: connectionId,
            kind: .upload,
            remotePath: remotePath,
            localPath: localPath,
            totalBytes: totalBytes,
            bytesTransferred: 0,
            status: .queued
        )
        transfers.append(transfer)
        scheduleRun(for: connectionId)
    }

    func clearCompleted() {
        transfers.removeAll { $0.status == .completed || $0.status == .failed }
    }

    // MARK: - Per-connection run loop

    /// Ensure a single Task drains the queue for this connection. Runs
    /// each pending transfer sequentially via the FFI; on completion or
    /// failure, picks up the next pending one for the same connection.
    private func scheduleRun(for connectionId: String) {
        // If a runner is already in flight for this connection, the
        // existing loop will pick up the newly-appended transfer on its
        // next iteration. No new task needed.
        if runningPerConnection[connectionId] != nil { return }

        let task = Task { @MainActor [weak self] in
            while let self {
                guard let nextIdx = self.transfers.firstIndex(where: {
                    $0.connectionId == connectionId && $0.status == .queued
                }) else { break }

                self.transfers[nextIdx].status = .inProgress
                let snapshot = self.transfers[nextIdx]
                await self.runTransfer(snapshot)
            }
            self?.runningPerConnection[connectionId] = nil
        }
        runningPerConnection[connectionId] = task
    }

    private func runTransfer(_ transfer: Transfer) async {
        let result: Result<UInt64, Error> = await Task.detached {
            do {
                let bytes: UInt64
                switch transfer.kind {
                case .download:
                    bytes = try rshellSftpDownload(
                        connectionId: transfer.connectionId,
                        remotePath: transfer.remotePath,
                        localPath: transfer.localPath,
                        expectedSize: transfer.totalBytes
                    )
                case .upload:
                    bytes = try rshellSftpUpload(
                        connectionId: transfer.connectionId,
                        localPath: transfer.localPath,
                        remotePath: transfer.remotePath
                    )
                }
                return .success(bytes)
            } catch {
                return .failure(error)
            }
        }.value

        // Update the matching transfer by id (the one we set to inProgress
        // earlier — the snapshot may now point at a stale index).
        guard let idx = transfers.firstIndex(where: { $0.id == transfer.id }) else { return }

        switch result {
        case .success(let bytes):
            transfers[idx].bytesTransferred = bytes
            transfers[idx].status = .completed
            logger.info("Transfer completed: \(transfer.remotePath, privacy: .public) (\(bytes) bytes)")

            // Reveal the downloaded file in Finder. Mirrors how Safari
            // and most macOS browsers behave on download completion;
            // the user almost always wants to do something with the
            // file next. Skip for uploads — the local source is
            // unchanged and the user is interacting with our window.
            if transfer.kind == .download {
                let url = URL(fileURLWithPath: transfer.localPath)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .failure(let error):
            transfers[idx].status = .failed
            transfers[idx].error = error.localizedDescription
            logger.error("Transfer failed for \(transfer.remotePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Progress

    private func handleProgress(connectionId: String, payload: String) {
        // Rust sends `{"path": ..., "bytesTransferred": ..., "totalBytes": ...}`
        struct Wire: Decodable {
            let path: String
            let bytesTransferred: UInt64
            let totalBytes: UInt64
        }
        guard let data = payload.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return }

        // Only update transfers in flight — completed / failed shouldn't
        // appear to make backwards progress if a stale event arrives.
        guard let idx = transfers.firstIndex(where: {
            $0.connectionId == connectionId
                && $0.remotePath == wire.path
                && $0.status == .inProgress
        }) else { return }

        transfers[idx].bytesTransferred = wire.bytesTransferred
        if wire.totalBytes > 0 && transfers[idx].totalBytes == 0 {
            transfers[idx].totalBytes = wire.totalBytes
        }
    }
}

// MARK: - Models

struct Transfer: Identifiable {
    enum Kind { case download, upload }
    enum Status { case queued, inProgress, completed, failed }

    let id: UUID
    let connectionId: String
    let kind: Kind
    let remotePath: String
    let localPath: String
    var totalBytes: UInt64
    var bytesTransferred: UInt64
    var status: Status
    var error: String?

    var progress: Double {
        totalBytes > 0 ? Double(bytesTransferred) / Double(totalBytes) : 0
    }

    var displayName: String {
        // Last path component of whichever side is the "destination
        // identity" — for downloads that's the remote name (what the
        // user picked), for uploads also the remote (where it landed).
        (remotePath as NSString).lastPathComponent
    }
}

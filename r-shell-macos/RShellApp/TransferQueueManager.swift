import Foundation
import OSLog
import RShellMacOS

/// Manages background file transfers with queue, progress tracking, and
/// concurrency control (max 2 simultaneous transfers).
@MainActor
class TransferQueueManager: ObservableObject {
    static let shared = TransferQueueManager()
    private let logger = Logger(subsystem: "com.r-shell", category: "transfer-queue")
    private let queue = DispatchQueue(label: "com.r-shell.transfer", qos: .utility)

    @Published var items: [TransferItem] = []
    @Published var activeCount = 0

    private let maxConcurrent = 2
    private var inFlight = 0

    private init() {}

    // MARK: - Enqueue

    func enqueueUpload(connectionId: String, localPath: String, remotePath: String) {
        let size = (try? FileManager.default.attributesOfItem(atPath: localPath))?[.size] as? UInt64 ?? 0
        let item = TransferItem(
            id: UUID().uuidString,
            direction: .upload,
            localPath: localPath,
            remotePath: remotePath,
            size: size,
            bytesTransferred: 0,
            status: .queued,
            connectionId: connectionId
        )
        items.append(item)
        processNext()
    }

    func enqueueDownload(connectionId: String, remotePath: String, localPath: String) {
        let item = TransferItem(
            id: UUID().uuidString,
            direction: .download,
            localPath: localPath,
            remotePath: remotePath,
            size: 0,
            bytesTransferred: 0,
            status: .queued,
            connectionId: connectionId
        )
        items.append(item)
        processNext()
    }

    func enqueueTransfers(connectionId: String, transfers: [(local: String, remote: String)], direction: TransferDirection) {
        for t in transfers {
            switch direction {
            case .upload: enqueueUpload(connectionId: connectionId, localPath: t.local, remotePath: t.remote)
            case .download: enqueueDownload(connectionId: connectionId, remotePath: t.remote, localPath: t.local)
            }
        }
    }

    // MARK: - Cancel

    func cancel(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[idx]
        if item.status == .inProgress { inFlight -= 1 }
        items[idx] = TransferItem(
            id: item.id, direction: item.direction,
            localPath: item.localPath, remotePath: item.remotePath,
            size: item.size, bytesTransferred: item.bytesTransferred,
            status: .failed, error: "Cancelled",
            connectionId: item.connectionId
        )
        activeCount = inFlight
        processNext()
    }

    func cancelAll(connectionId: String) {
        for item in items where item.connectionId == connectionId && item.status == .queued {
            cancel(id: item.id)
        }
    }

    // MARK: - Clear completed

    func clearCompleted() {
        items.removeAll { $0.status == .completed || $0.status == .failed }
    }

    // MARK: - Queue processing

    private func processNext() {
        while inFlight < maxConcurrent {
            guard let idx = items.firstIndex(where: { $0.status == .queued }) else { break }
            inFlight += 1
            activeCount = inFlight
            items[idx].status = .inProgress
            let item = items[idx]
            queue.async { [weak self] in
                self?.execute(item: item, index: idx)
            }
        }
    }

    private func execute(item: TransferItem, index: Int) {
        // Once FFI is wired: call rshell_keychain_load → rshell_connect → sftp list/download/upload
        let success = simulateTransfer(item: item)
        Task { @MainActor in
            guard index < items.count else { return }
            if success {
                items[index].status = .completed
                items[index].bytesTransferred = items[index].size
            } else {
                items[index].status = .failed
                items[index].error = "Transfer failed"
            }
            inFlight -= 1
            activeCount = inFlight
            processNext()
        }
    }

    private func simulateTransfer(item: TransferItem) -> Bool {
        Thread.sleep(forTimeInterval: 0.5)
        return true
    }
}

import AppKit
import Foundation
import OSLog
import RShellMacOS

/// Local and remote file operations. Runs on a background queue.
/// Once FFI is wired, these call `rshell_*` functions.
@MainActor
class FileOperationsManager: ObservableObject {
    static let shared = FileOperationsManager()
    private let logger = Logger(subsystem: "com.r-shell", category: "file-ops")
    private let queue = DispatchQueue(label: "com.r-shell.fileops", qos: .utility)

    private init() {}

    // MARK: - Local files

    func listLocalFiles(path: String) async -> [FileEntry] {
        let url = URL(fileURLWithPath: path)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else {
            return []
        }

        return contents.compactMap { url in
            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else { return nil }
            return FileEntry(
                name: url.lastPathComponent,
                path: url.path,
                size: UInt64(attrs.fileSize ?? 0),
                modified: attrs.contentModificationDate,
                permissions: nil,
                type: attrs.isDirectory == true ? .directory : .file
            )
        }
        .sorted { $0.type == .directory && $1.type != .directory || ($0.type == $1.type && $0.name.localizedStandardCompare($1.name) == .orderedAscending) }
    }

    func openInFinder(path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func trashItem(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        queue.async {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
    }

    func deleteLocalItem(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            logger.error("Delete failed: \(error.localizedDescription)")
            return false
        }
    }

    func createLocalDirectory(path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return true
        } catch {
            logger.error("mkdir failed: \(error.localizedDescription)")
            return false
        }
    }

    func renameLocalItem(from: String, to: String) -> Bool {
        do {
            try FileManager.default.moveItem(atPath: from, toPath: to)
            return true
        } catch {
            logger.error("rename failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Remote files (FFI stubs)

    func listRemoteFiles(connectionId: String, path: String) async -> [FileEntry] {
        // Once FFI: rshell_execute_command or SFTP channel
        return []
    }

    func deleteRemoteItem(connectionId: String, path: String) async -> Bool {
        return false
    }

    func createRemoteDirectory(connectionId: String, path: String) async -> Bool {
        return false
    }

    func renameRemoteItem(connectionId: String, from: String, to: String) async -> Bool {
        return false
    }

    /// Open a remote text file for editing — downloads to a temp file and opens in the
    /// system editor, or shows the built-in FileEditView.
    func openRemoteFile(connectionId: String, path: String) async -> String? {
        return nil  // Returns file content when FFI wired
    }

    func saveRemoteFile(connectionId: String, path: String, content: String) async -> Bool {
        return false
    }
}

import Foundation

final class MobileSFTPBridge {
    static let shared = MobileSFTPBridge()

    private let queue = DispatchQueue(
        label: "com.r-shell.mobile.sftp-bridge",
        qos: .utility,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )

    private init() {}

    func listDir(connectionId: String, path: String) async throws -> [FfiFileEntry] {
        try await run {
            try rshellSftpListDir(connectionId: connectionId, path: path)
        }
    }

    func createDir(connectionId: String, path: String) async throws {
        try await run {
            try rshellSftpCreateDir(connectionId: connectionId, path: path)
        }
    }

    func rename(connectionId: String, oldPath: String, newPath: String) async throws {
        try await run {
            try rshellSftpRename(connectionId: connectionId, oldPath: oldPath, newPath: newPath)
        }
    }

    func deleteFile(connectionId: String, path: String) async throws {
        try await run {
            try rshellSftpDeleteFile(connectionId: connectionId, path: path)
        }
    }

    func deleteDir(connectionId: String, path: String) async throws {
        try await run {
            try rshellSftpDeleteDir(connectionId: connectionId, path: path)
        }
    }

    @discardableResult
    func download(
        transferId: UUID = UUID(),
        connectionId: String,
        remotePath: String,
        localPath: String,
        expectedSize: UInt64
    ) async throws -> UInt64 {
        try await run {
            try rshellSftpDownload(
                transferId: transferId.uuidString,
                connectionId: connectionId,
                remotePath: remotePath,
                localPath: localPath,
                expectedSize: expectedSize
            )
        }
    }

    @discardableResult
    func upload(
        transferId: UUID = UUID(),
        connectionId: String,
        localPath: String,
        remotePath: String
    ) async throws -> UInt64 {
        try await run {
            try rshellSftpUpload(
                transferId: transferId.uuidString,
                connectionId: connectionId,
                localPath: localPath,
                remotePath: remotePath
            )
        }
    }

    func readRemoteTextFile(
        connectionId: String,
        remotePath: String,
        fileName: String,
        expectedSize: UInt64,
        maxBytes: UInt64 = 1_048_576
    ) async throws -> String {
        if expectedSize > maxBytes {
            throw MobileSFTPBridgeError.fileTooLarge(fileName: fileName, size: expectedSize)
        }

        let tempURL = temporaryURL(fileName: fileName)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = try await download(
            connectionId: connectionId,
            remotePath: remotePath,
            localPath: tempURL.path,
            expectedSize: expectedSize
        )

        let data = try Data(contentsOf: tempURL)
        if UInt64(data.count) > maxBytes {
            throw MobileSFTPBridgeError.fileTooLarge(fileName: fileName, size: UInt64(data.count))
        }
        if let content = String(data: data, encoding: .utf8) {
            return content
        }
        if let content = String(data: data, encoding: .ascii) {
            return content
        }
        throw MobileSFTPBridgeError.unsupportedEncoding(fileName: fileName)
    }

    func saveRemoteTextFile(
        connectionId: String,
        remotePath: String,
        fileName: String,
        content: String
    ) async throws {
        let tempURL = temporaryURL(fileName: fileName)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let data = content.data(using: .utf8) else {
            throw MobileSFTPBridgeError.unsupportedEncoding(fileName: fileName)
        }
        try data.write(to: tempURL, options: .atomic)

        _ = try await upload(
            connectionId: connectionId,
            localPath: tempURL.path,
            remotePath: remotePath
        )
    }

    func downloadForExport(
        connectionId: String,
        remotePath: String,
        fileName: String,
        expectedSize: UInt64
    ) async throws -> URL {
        let tempURL = temporaryURL(fileName: fileName)
        _ = try await download(
            connectionId: connectionId,
            remotePath: remotePath,
            localPath: tempURL.path,
            expectedSize: expectedSize
        )
        return tempURL
    }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func temporaryURL(fileName: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("midnight-ssh-mobile-sftp", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let sanitized = fileName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let suffix = sanitized.isEmpty ? "remote-file" : sanitized
        return directory.appendingPathComponent("\(UUID().uuidString)-\(suffix)")
    }
}

enum MobileSFTPBridgeError: Error, LocalizedError {
    case fileTooLarge(fileName: String, size: UInt64)
    case unsupportedEncoding(fileName: String)
    case invalidRemoteName(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let fileName, let size):
            let formatted = ByteCountFormatter.string(
                fromByteCount: Int64(size),
                countStyle: .file
            )
            return "\(fileName) is too large to edit safely (\(formatted))."
        case .unsupportedEncoding(let fileName):
            return "\(fileName) is not a UTF-8 text file."
        case .invalidRemoteName(let name):
            return "\(name) is not a valid remote name."
        }
    }
}

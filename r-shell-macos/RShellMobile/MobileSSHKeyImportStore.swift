import Foundation

enum MobileSSHKeyImportError: Error, LocalizedError {
    case unreadable
    case tooLarge
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The selected file could not be read as a private key."
        case .tooLarge:
            return "The selected private key is too large."
        case .unsupportedFormat:
            return "The selected file does not look like a supported private key."
        }
    }
}

enum MobileSSHKeyImportStore {
    private static let maxKeyBytes = 256 * 1024
    private static let fileManager = FileManager.default

    static func importKey(from sourceURL: URL) throws -> URL {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let resourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard resourceValues.isDirectory != true else {
            throw MobileSSHKeyImportError.unreadable
        }
        if let fileSize = resourceValues.fileSize, fileSize > maxKeyBytes {
            throw MobileSSHKeyImportError.tooLarge
        }

        let data = try Data(contentsOf: sourceURL)
        guard !data.isEmpty, data.count <= maxKeyBytes else {
            throw data.isEmpty ? MobileSSHKeyImportError.unreadable : MobileSSHKeyImportError.tooLarge
        }
        guard let text = String(data: data, encoding: .utf8), looksLikePrivateKey(text) else {
            throw MobileSSHKeyImportError.unsupportedFormat
        }

        let directory = try keysDirectory()
        let targetURL = directory.appendingPathComponent(targetFilename(for: sourceURL))
        try data.write(to: targetURL, options: [.atomic])
        try applyProtection(to: targetURL)
        try excludeFromBackups(targetURL)
        return targetURL
    }

    static func deleteImportedKey(at path: String?) {
        guard let path, isManagedKeyPath(path) else { return }
        try? fileManager.removeItem(atPath: path)
    }

    static func isManagedKeyPath(_ path: String) -> Bool {
        guard let directory = try? keysDirectory() else { return false }
        let keyURL = URL(fileURLWithPath: path).standardizedFileURL
        return keyURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    private static func keysDirectory() throws -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let directory = base
            .appendingPathComponent("midnight-ssh", isDirectory: true)
            .appendingPathComponent("keys", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try applyProtection(to: directory)
        try excludeFromBackups(directory)
        return directory
    }

    private static func targetFilename(for sourceURL: URL) -> String {
        let rawName = sourceURL.lastPathComponent.isEmpty ? "ssh-key" : sourceURL.lastPathComponent
        let sanitized = rawName
            .unicodeScalars
            .map { scalar -> String in
                let allowed = CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "._-"))
                    .contains(scalar)
                return allowed ? String(scalar) : "_"
            }
            .joined()
        let base = String(sanitized).prefix(80)
        return "\(UUID().uuidString)-\(base.isEmpty ? "ssh-key" : String(base))"
    }

    private static func looksLikePrivateKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("ssh-rsa "),
              !trimmed.hasPrefix("ssh-ed25519 "),
              !trimmed.hasPrefix("ecdsa-sha2-") else {
            return false
        }

        let markers = [
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN EC PRIVATE KEY-----",
            "-----BEGIN DSA PRIVATE KEY-----",
            "-----BEGIN PRIVATE KEY-----",
            "PuTTY-User-Key-File-",
        ]
        return markers.contains { trimmed.contains($0) }
    }

    private static func applyProtection(to url: URL) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    private static func excludeFromBackups(_ url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
}

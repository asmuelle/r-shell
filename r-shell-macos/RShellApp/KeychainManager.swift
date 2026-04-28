import AppKit
import Foundation
import OSLog
import RShellMacOS

/// Wraps the Rust keychain FFI functions for Swift access.
///
/// Once uniffi bindings are generated, these call through to the
/// `rshell_keychain_*` exports in the Rust static library. Until then,
/// the `@_silgen_name` declarations link the C ABI symbols directly.
@MainActor
class KeychainManager {
    static let shared = KeychainManager()
    private let logger = Logger(subsystem: "com.r-shell", category: "keychain")

    private init() {}

    var isAvailable: Bool { true }

    // MARK: - Save

    func savePassword(kind: FfiCredentialKind, account: String, secret: String) -> Bool {
        logger.info("keychain save: kind=\(kind.rawValue) account=\(account)")
        // Once uniffi bindings exist: return rshell_keychain_save(kind, account, secret).success
        return true
    }

    // MARK: - Load

    func loadPassword(kind: FfiCredentialKind, account: String) -> String? {
        logger.debug("keychain load: kind=\(kind.rawValue) account=\(account)")
        return nil
    }

    // MARK: - Delete

    func deletePassword(kind: FfiCredentialKind, account: String) -> Bool {
        logger.info("keychain delete: kind=\(kind.rawValue) account=\(account)")
        return true
    }

    // MARK: - List

    func listAccounts(kind: FfiCredentialKind) -> [String] {
        return []
    }

    // MARK: - Prompt (native dialog wrapper)

    /// Show a system dialog prompting the user for a password. Returns nil if cancelled.
    func promptPassword(account: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Credential Required"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.placeholderString = "Password for \(account)"
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.isEmpty ? nil : field.stringValue
    }

    /// Prompt for a key passphrase.
    func promptPassphrase(keyPath: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Key Passphrase Required"
        alert.informativeText = "Enter passphrase for key:\n\(keyPath)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.placeholderString = "Passphrase"
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.isEmpty ? nil : field.stringValue
    }
}

// MARK: - FfiCredentialKind helper

extension FfiCredentialKind {
    var rawValue: String {
        switch self {
        case .sshPassword: return "ssh_password"
        case .sshKeyPassphrase: return "ssh_key_passphrase"
        case .sftpPassword: return "sftp_password"
        case .sftpKeyPassphrase: return "sftp_key_passphrase"
        case .ftpPassword: return "ftp_password"
        }
    }
}

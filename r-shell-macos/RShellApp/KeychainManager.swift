import AppKit
import Foundation
import OSLog
import RShellMacOS

/// Wraps the Rust keychain FFI for Swift access. Uses `rshell_keychain_*`
/// from the uniffi bindings; the actual storage is the macOS Keychain via
/// r-shell-core's `security-framework` integration.
@MainActor
class KeychainManager {
    static let shared = KeychainManager()
    private let logger = Logger(subsystem: "com.r-shell", category: "keychain")

    private init() {}

    var isAvailable: Bool { rshellKeychainIsSupported() }

    // MARK: - Save

    @discardableResult
    func savePassword(kind: FfiCredentialKind, account: String, secret: String) -> Bool {
        let result = rshellKeychainSave(kind: kind, account: account, secret: secret)
        if !result.success {
            logger.error("keychain save failed: \(result.error ?? "?", privacy: .public)")
        }
        return result.success
    }

    // MARK: - Load

    /// Returns the stored secret, or `nil` if no entry exists or the
    /// underlying call errored. Errors are logged but not surfaced — the
    /// caller's expected fallback is a UI prompt.
    func loadPassword(kind: FfiCredentialKind, account: String) -> String? {
        let result = rshellKeychainLoad(kind: kind, account: account)
        if !result.success {
            logger.error("keychain load failed: \(result.error ?? "?", privacy: .public)")
            return nil
        }
        // Rust returns `success: true, value: nil` when no entry exists.
        return result.value
    }

    // MARK: - Delete

    @discardableResult
    func deletePassword(kind: FfiCredentialKind, account: String) -> Bool {
        let result = rshellKeychainDelete(kind: kind, account: account)
        if !result.success {
            logger.error("keychain delete failed: \(result.error ?? "?", privacy: .public)")
        }
        return result.success
    }

    // MARK: - List

    func listAccounts(kind: FfiCredentialKind) -> [String] {
        rshellKeychainList(kind: kind)
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

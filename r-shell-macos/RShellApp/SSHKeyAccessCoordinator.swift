import Foundation
import RShellMacOS

final class PreparedSSHKey {
    let keyPath: String?
    let useAgent: Bool
    let agentIdentityHint: String?

    private var cleanup: (() -> Void)?

    init(
        keyPath: String?,
        useAgent: Bool = false,
        agentIdentityHint: String? = nil,
        cleanup: (() -> Void)? = nil
    ) {
        self.keyPath = keyPath
        self.useAgent = useAgent
        self.agentIdentityHint = agentIdentityHint
        self.cleanup = cleanup
    }

    func stop() {
        cleanup?()
        cleanup = nil
    }

    deinit {
        stop()
    }
}

enum SSHKeyAccessError: LocalizedError {
    case missingKey
    case bookmarkDenied(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Choose, import, generate, or select an SSH agent identity before connecting."
        case .bookmarkDenied(let path):
            return "midnight-ssh does not currently have access to \(path). Choose the key again to renew access."
        }
    }
}

enum SSHKeyAccessCoordinator {
    static func prepare(_ reference: SSHKeyReference?) throws -> PreparedSSHKey {
        guard let reference else { throw SSHKeyAccessError.missingKey }

        switch reference {
        case .plainPath(let path):
            return PreparedSSHKey(keyPath: path)

        case .securityScopedBookmark(let data):
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let didStartAccess = url.startAccessingSecurityScopedResource()
            guard didStartAccess || FileManager.default.isReadableFile(atPath: url.path) else {
                throw SSHKeyAccessError.bookmarkDenied(url.path)
            }
            return PreparedSSHKey(keyPath: url.path) {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

        case .importedVaultKey(let id), .generatedVaultKey(let id):
            let materializedURL = try SSHKeyVault.shared.materializeKey(id: id)
            return PreparedSSHKey(keyPath: materializedURL.path) {
                try? FileManager.default.removeItem(at: materializedURL)
            }

        case .agent(let identityHint):
            return PreparedSSHKey(
                keyPath: nil,
                useAgent: true,
                agentIdentityHint: identityHint
            )
        }
    }
}

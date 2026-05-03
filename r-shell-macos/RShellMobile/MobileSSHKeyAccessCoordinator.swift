import Foundation

final class PreparedMobileSSHKey: @unchecked Sendable {
    let keyPath: String?

    private var cleanup: (() -> Void)?

    init(keyPath: String?, cleanup: (() -> Void)? = nil) {
        self.keyPath = keyPath
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

enum MobileSSHKeyAccessError: LocalizedError {
    case missingKey
    case unreadableKey(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Generate or import an SSH key before connecting."
        case .unreadableKey(let path):
            return "The SSH key is not readable at \(path). Import it again."
        }
    }
}

enum MobileSSHKeyAccessCoordinator {
    static func prepare(_ reference: MobileSSHKeyReference?) throws -> PreparedMobileSSHKey {
        guard let reference else { throw MobileSSHKeyAccessError.missingKey }

        switch reference {
        case .plainPath(let path):
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw MobileSSHKeyAccessError.unreadableKey(path)
            }
            return PreparedMobileSSHKey(keyPath: path)

        case .vaultKey(let id), .generatedVaultKey(let id):
            let materializedURL = try MobileSSHKeyVault.shared.materializeKey(id: id)
            return PreparedMobileSSHKey(keyPath: materializedURL.path) {
                try? FileManager.default.removeItem(at: materializedURL)
            }
        }
    }
}

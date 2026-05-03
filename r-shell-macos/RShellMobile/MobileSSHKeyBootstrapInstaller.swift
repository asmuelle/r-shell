import Foundation

enum MobileSSHKeyBootstrapError: LocalizedError {
    case missingPassword
    case missingPublicKey
    case installFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPassword:
            return "Enter the server password to install the generated key."
        case .missingPublicKey:
            return "Generate a public key before installing it on the server."
        case .installFailed(let detail):
            return "Could not install the public key: \(detail)"
        case .verificationFailed(let detail):
            return "The key was installed, but key login could not be verified: \(detail)"
        }
    }
}

final class MobileSSHKeyBootstrapInstaller: @unchecked Sendable {
    static let shared = MobileSSHKeyBootstrapInstaller()

    private let queue = DispatchQueue(
        label: "com.r-shell.mobile.ssh-key-bootstrap",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    private init() {}

    func installAndVerify(
        profile: MobileConnectionProfile,
        password: String,
        reference: MobileSSHKeyReference,
        publicKey: String
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.performInstallAndVerify(
                        profile: profile,
                        password: password,
                        reference: reference,
                        publicKey: publicKey
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performInstallAndVerify(
        profile: MobileConnectionProfile,
        password: String,
        reference: MobileSSHKeyReference,
        publicKey: String
    ) throws {
        let password = password.trimmingCharacters(in: .newlines)
        guard !password.isEmpty else { throw MobileSSHKeyBootstrapError.missingPassword }

        let publicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publicKey.isEmpty else { throw MobileSSHKeyBootstrapError.missingPublicKey }

        let bootstrapConnectionId = try rshellConnect(config: FfiConnectConfig(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: password,
            keyPath: nil,
            passphrase: nil,
            useAgent: false,
            agentIdentityHint: nil,
            sessionId: "ios-key-bootstrap-\(UUID().uuidString)"
        ))
        defer {
            _ = rshellDisconnect(connectionId: bootstrapConnectionId)
        }

        let installResult = rshellExecuteCommand(
            connectionId: bootstrapConnectionId,
            command: Self.installCommand(publicKey: publicKey)
        )
        guard installResult.success else {
            throw MobileSSHKeyBootstrapError.installFailed(
                installResult.error ?? installResult.value ?? "Remote command failed."
            )
        }

        let preparedKey = try MobileSSHKeyAccessCoordinator.prepare(reference)
        defer {
            preparedKey.stop()
        }

        let verifiedConnectionId: String
        do {
            verifiedConnectionId = try rshellConnect(config: FfiConnectConfig(
                host: profile.host,
                port: profile.port,
                username: profile.username,
                password: nil,
                keyPath: preparedKey.keyPath,
                passphrase: nil,
                useAgent: false,
                agentIdentityHint: nil,
                sessionId: "ios-key-verify-\(UUID().uuidString)"
            ))
        } catch {
            throw MobileSSHKeyBootstrapError.verificationFailed(error.localizedDescription)
        }
        _ = rshellDisconnect(connectionId: verifiedConnectionId)
    }

    private static func installCommand(publicKey: String) -> String {
        let quotedKey = shellQuote(publicKey)
        return """
        set -eu
        umask 077
        mkdir -p "$HOME/.ssh"
        touch "$HOME/.ssh/authorized_keys"
        chmod 700 "$HOME/.ssh"
        chmod 600 "$HOME/.ssh/authorized_keys"
        key=\(quotedKey)
        if ! grep -Fqx "$key" "$HOME/.ssh/authorized_keys"; then
          printf '%s\\n' "$key" >> "$HOME/.ssh/authorized_keys"
        fi
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

import Foundation

enum MobileSessionStatus: Equatable {
    case disconnected
    case connecting
    case connected(connectionId: String)
    case failed(String)

    var label: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    var isBusy: Bool {
        if case .connecting = self { return true }
        return false
    }

    var failureMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

@MainActor
final class MobileSessionStore: ObservableObject {
    @Published private var statuses: [String: MobileSessionStatus] = [:]

    func status(for profile: MobileConnectionProfile) -> MobileSessionStatus {
        statuses[profile.id] ?? .disconnected
    }

    func diagnosticsSnapshot(for profiles: [MobileConnectionProfile]) -> [MobileSessionDiagnostics] {
        profiles.map { profile in
            MobileSessionDiagnostics(
                profileIdHash: MobileDiagnosticsRedactor.hash(profile.id),
                status: status(for: profile).diagnosticsLabel
            )
        }
    }

    func connect(
        profile: MobileConnectionProfile,
        password: String?,
        passphrase: String?,
        onSuccess: @escaping () -> Void,
        onFailure: ((String) -> Void)? = nil
    ) {
        guard !status(for: profile).isBusy else { return }

        statuses[profile.id] = .connecting
        let sessionId = UUID().uuidString
        let preparedKey: PreparedMobileSSHKey?

        do {
            preparedKey = profile.authMethod == .publicKey
                ? try MobileSSHKeyAccessCoordinator.prepare(profile.sshKeyReference)
                : nil
        } catch {
            let message = Self.describeConnectFailure(error, profile: profile)
            statuses[profile.id] = .failed(message)
            onFailure?(message)
            return
        }

        connectInBackground(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: password,
            preparedKey: preparedKey,
            passphrase: passphrase,
            sessionId: sessionId
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let connectionId):
                    self.statuses[profile.id] = .connected(connectionId: connectionId)
                    onSuccess()
                case .failure(let error):
                    let message = Self.describeConnectFailure(error, profile: profile)
                    self.statuses[profile.id] = .failed(message)
                    onFailure?(message)
                }
            }
        }
    }

    func disconnect(profile: MobileConnectionProfile) {
        guard case .connected(let connectionId) = status(for: profile) else {
            statuses[profile.id] = .disconnected
            return
        }

        let result = rshellDisconnect(connectionId: connectionId)
        if result.success {
            statuses[profile.id] = .disconnected
        } else {
            let message = MobileDiagnosticsRedactor.redactSecrets(result.error ?? "Disconnect failed")
            statuses[profile.id] = .failed(message)
        }
    }

    private static func describeConnectFailure(
        _ error: Error,
        profile: MobileConnectionProfile
    ) -> String {
        let fallback = error.localizedDescription == "The operation couldn’t be completed."
            ? String(reflecting: error)
            : error.localizedDescription

        guard let connectError = error as? ConnectError else {
            return MobileDiagnosticsRedactor.redactSecrets(fallback)
        }

        let message: String
        switch connectError {
        case .ConfigInvalid(let detail):
            message = detail
        case .PassphraseRequired(let detail):
            message = "The private key needs a passphrase. Edit this connection, enter the key passphrase, and save it in iOS Keychain. Detail: \(detail)"
        case .AuthFailed(let detail):
            if profile.authMethod == .publicKey {
                message = """
                The server rejected this SSH key. Make sure the exact public key from midnight-ssh is on one line in \(profile.username)'s ~/.ssh/authorized_keys, the file belongs to \(profile.username), ~/.ssh is chmod 700, authorized_keys is chmod 600, and sshd allows PubkeyAuthentication. Detail: \(detail)
                """
            } else {
                message = "Authentication failed. Check the saved password for \(profile.username). Detail: \(detail)"
            }
        case .HostKeyMismatch(let detail):
            message = "The server host key changed. Detail: \(detail)"
        case .Network(let detail):
            message = "Could not reach \(profile.host):\(profile.port). Detail: \(detail)"
        case .Other(let detail):
            message = detail
        }

        return MobileDiagnosticsRedactor.redactSecrets(message)
    }

    private nonisolated func connectInBackground(
        host: String,
        port: UInt16,
        username: String,
        password: String?,
        preparedKey: PreparedMobileSSHKey?,
        passphrase: String?,
        sessionId: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                preparedKey?.stop()
            }

            let config = FfiConnectConfig(
                host: host,
                port: port,
                username: username,
                password: password,
                keyPath: preparedKey?.keyPath,
                passphrase: passphrase,
                useAgent: false,
                agentIdentityHint: nil,
                sessionId: sessionId
            )

            do {
                completion(.success(try rshellConnect(config: config)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

struct MobileSessionDiagnostics: Codable {
    let profileIdHash: String
    let status: String
}

private extension MobileSessionStatus {
    var diagnosticsLabel: String {
        switch self {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .failed:
            return "failed"
        }
    }
}

import SwiftUI
import RShellMacOS

@MainActor
struct ConnectionConfidenceView: View {
    let profile: ConnectionProfile
    let status: TerminalConnectionStatus?

    private var keyMetadata: SSHKeyMetadata? {
        SSHKeyVault.shared.metadata(for: profile.sshKeyReference)
    }

    private var credentialState: (label: String, color: Color, icon: String) {
        switch profile.authMethod {
        case .password:
            let hasPassword = KeychainManager.shared.hasPassword(
                kind: .sshPassword,
                account: profile.keychainAccount
            )
            return hasPassword
                ? ("Password saved", .green, "key.fill")
                : ("Password missing", .orange, "key.slash")
        case .publicKey:
            if profile.sshKeyReference?.isAgent == true {
                return ("SSH agent", .blue, "person.crop.circle.badge.key")
            }
            guard profile.sshKeyReference != nil else {
                return ("Key missing", .orange, "key.slash")
            }
            let hasPassphrase = KeychainManager.shared.hasPassword(
                kind: .sshKeyPassphrase,
                account: profile.keychainAccount
            )
            return hasPassphrase
                ? ("Key + passphrase saved", .green, "key.fill")
                : ("Key ready", .green, "key")
        }
    }

    private var statusState: (label: String, color: Color) {
        switch status {
        case .connected:
            return ("Connected", .green)
        case .connecting:
            return ("Connecting", .orange)
        case .disconnected:
            return ("Disconnected", .secondary)
        case .error:
            return ("Error", .red)
        case nil:
            return ("Unknown", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Connection Confidence", systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.medium))
                Spacer()
                statusBadge
            }

            VStack(spacing: 0) {
                detailRow("Endpoint", value: "\(profile.username)@\(profile.host):\(profile.port)", icon: "network")
                Divider()
                detailRow("Mode", value: profile.kind.displayName, icon: profile.kind.supportsTerminal ? "terminal" : "folder")
                Divider()
                credentialRow
                if let keyMetadata {
                    Divider()
                    detailRow("Key", value: keyMetadata.label, icon: "key")
                    if let fingerprint = keyMetadata.fingerprint {
                        Divider()
                        detailRow("Fingerprint", value: fingerprint, icon: "number")
                    }
                }
                Divider()
                detailRow("Last connected", value: lastConnectedText, icon: "clock")
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Button {
                    RemoteCommandRunner.copy(sshCommand)
                } label: {
                    Label("Copy SSH Command", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let publicKey = keyMetadata?.publicKey {
                    Button {
                        RemoteCommandRunner.copy(publicKey)
                    } label: {
                        Label("Copy Public Key", systemImage: "key.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var statusBadge: some View {
        let state = statusState
        return HStack(spacing: 5) {
            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
            Text(state.label)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(state.color.opacity(0.12), in: Capsule())
    }

    private var credentialRow: some View {
        let state = credentialState
        return HStack(spacing: 8) {
            Image(systemName: state.icon)
                .foregroundStyle(state.color)
                .frame(width: 18)
            Text("Credential")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(state.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(state.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func detailRow(_ label: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var sshCommand: String {
        "ssh -p \(profile.port) \(profile.username)@\(profile.host)"
    }

    private var lastConnectedText: String {
        guard let date = profile.lastConnected else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

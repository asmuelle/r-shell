import SwiftUI
import UIKit

struct MobileConnectionConfidenceView: View {
    @EnvironmentObject private var keychainManager: MobileKeychainManager

    let profile: MobileConnectionProfile
    let status: MobileSessionStatus

    private var keyMetadata: MobileSSHKeyMetadata? {
        MobileSSHKeyVault.shared.metadata(for: profile.sshKeyReference)
    }

    private var credentialState: (label: String, color: Color, icon: String) {
        switch profile.authMethod {
        case .password:
            let hasPassword = keychainManager.hasSecret(
                kind: .sshPassword,
                account: profile.keychainAccount
            )
            return hasPassword
                ? ("Password saved", .green, "key.fill")
                : ("Password missing", .orange, "key.slash")
        case .publicKey:
            guard profile.sshKeyReference != nil else {
                return ("Key missing", .orange, "key.slash")
            }
            let hasPassphrase = keychainManager.hasSecret(
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
        case .failed:
            return ("Needs attention", .red)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Connection Confidence", systemImage: "checkmark.shield")
                    .font(.headline)
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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = sshCommand
                } label: {
                    Label("Copy SSH", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                if let publicKey = keyMetadata?.publicKey {
                    Button {
                        UIPasteboard.general.string = publicKey
                    } label: {
                        Label("Copy Public Key", systemImage: "key.viewfinder")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusBadge: some View {
        let state = statusState
        return HStack(spacing: 5) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
            Text(state.label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(state.color.opacity(0.12), in: Capsule())
    }

    private var credentialRow: some View {
        let state = credentialState
        return HStack(spacing: 8) {
            Image(systemName: state.icon)
                .foregroundStyle(state.color)
                .frame(width: 20)
            Text("Credential")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(state.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(state.color)
                .lineLimit(1)
        }
        .padding(10)
    }

    private func detailRow(_ label: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
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
        .padding(10)
    }

    private var sshCommand: String {
        "ssh -p \(profile.port) \(profile.username)@\(profile.host)"
    }

    private var lastConnectedText: String {
        guard let date = profile.lastConnected else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

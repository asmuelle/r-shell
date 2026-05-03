import SwiftUI
import UniformTypeIdentifiers

struct MobileSecurityVaultView: View {
    let profiles: [MobileConnectionProfile]

    @EnvironmentObject private var keychainManager: MobileKeychainManager
    @Environment(\.dismiss) private var dismiss

    @State private var exportDocument = MobileTextDocument()
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            List {
                Section("Vault") {
                    statusRow("Saved hosts", "\(profiles.count)", "server.rack")
                    statusRow("Public-key profiles", "\(profiles.filter { $0.authMethod == .publicKey }.count)", "key")
                    statusRow("Generated keys", "\(profiles.filter { $0.sshKeyReference?.isGenerated == true }.count)", "key.viewfinder")
                    statusRow("Vault unlocked", keychainManager.vaultUnlocked ? "Yes" : "No", "lock")
                }

                Section("Key References") {
                    ForEach(profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(profile.sshKeyReference?.displayName ?? "No SSH key")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let fingerprint = MobileSSHKeyVault.shared.metadata(for: profile.sshKeyReference)?.fingerprint {
                                Text(fingerprint)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Section("Export") {
                    Button {
                        exportVaultSummary()
                    } label: {
                        Label("Export Redacted Vault Summary", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("Security Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $exporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "midnight-ssh-vault-summary.json"
            ) { _ in }
        }
    }

    private func statusRow(_ title: String, _ value: String, _ systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func exportVaultSummary() {
        let rows = profiles.map { profile -> [String: String] in
            let metadata = MobileSSHKeyVault.shared.metadata(for: profile.sshKeyReference)
            return [
                "idHash": MobileDiagnosticsRedactor.hash(profile.id),
                "hostHash": MobileDiagnosticsRedactor.hash(profile.host),
                "authMethod": profile.authMethod.rawValue,
                "kind": profile.kind.rawValue,
                "hasSSHKey": profile.sshKeyReference == nil ? "false" : "true",
                "keySource": metadata?.source ?? "none",
                "fingerprint": metadata?.fingerprint ?? "",
            ]
        }
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "note": "This export is redacted and does not contain private keys or passwords.",
            "connections": rows,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        exportDocument = MobileTextDocument(text: String(data: data, encoding: .utf8) ?? "{}")
        exporting = true
    }
}

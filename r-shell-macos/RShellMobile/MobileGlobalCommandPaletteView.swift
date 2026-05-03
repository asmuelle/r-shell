import SwiftUI

struct MobileGlobalCommandPaletteView: View {
    let profiles: [MobileConnectionProfile]
    let selectedProfileId: String?
    let onSelectProfile: (MobileConnectionProfile) -> Void
    let onAddConnection: () -> Void
    let onOpenFleet: () -> Void
    let onOpenSecurityVault: () -> Void
    let onExportDiagnostics: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var actions: [MobilePaletteAction] {
        var result = [
            MobilePaletteAction(title: "Add Connection", subtitle: "Create an SSH or SFTP profile", systemImage: "plus.circle") {
                onAddConnection()
            },
            MobilePaletteAction(title: "Fleet Dashboard", subtitle: "Problem-first overview of saved hosts", systemImage: "rectangle.grid.2x2") {
                onOpenFleet()
            },
            MobilePaletteAction(title: "Security Vault", subtitle: "Inspect keys and credential state", systemImage: "lock.shield") {
                onOpenSecurityVault()
            },
            MobilePaletteAction(title: "Export Diagnostics", subtitle: "Create a redacted support bundle", systemImage: "square.and.arrow.up") {
                onExportDiagnostics()
            },
        ]

        for profile in profiles.sorted(by: profileSort) {
            result.append(MobilePaletteAction(
                title: "Open \(profile.name)",
                subtitle: "\(profile.username)@\(profile.host):\(profile.port)",
                systemImage: profile.kind.supportsTerminal ? "terminal" : "folder"
            ) {
                onSelectProfile(profile)
            })
        }

        return result
    }

    private var filteredActions: [MobilePaletteAction] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return actions }
        return actions.filter {
            $0.title.lowercased().contains(needle)
                || $0.subtitle.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "command")
                            .foregroundStyle(.secondary)
                        TextField("Run command or open server", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section("Commands") {
                    ForEach(filteredActions) { action in
                        Button {
                            dismiss()
                            action.run()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: action.systemImage)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title)
                                        .foregroundStyle(.primary)
                                    Text(action.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Command Palette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func profileSort(_ lhs: MobileConnectionProfile, _ rhs: MobileConnectionProfile) -> Bool {
        if lhs.id == selectedProfileId { return true }
        if rhs.id == selectedProfileId { return false }
        if lhs.favorite != rhs.favorite {
            return lhs.favorite && !rhs.favorite
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private struct MobilePaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let systemImage: String
    let run: () -> Void
}

import AppKit
import SwiftUI
import RShellMacOS

struct CommandPaletteView: View {
    let connections: [ConnectionProfile]
    let selectedConnection: ConnectionProfile?
    let activeTab: TerminalTab?
    let connectedHostCount: Int
    let onConnect: (ConnectionProfile) -> Void
    let onReconnectActive: () -> Void
    let onCloseActive: () -> Void
    let onOpenDashboard: () -> Void
    let onToggleSidebar: () -> Void
    let onToggleBottom: () -> Void
    let onToggleInspector: () -> Void
    let onExportDiagnostics: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var actions: [PaletteAction] {
        var result: [PaletteAction] = []

        if let selectedConnection {
            result.append(PaletteAction(
                title: "Connect to \(selectedConnection.name)",
                subtitle: "\(selectedConnection.username)@\(selectedConnection.host):\(selectedConnection.port)",
                icon: "bolt.horizontal.fill",
                isEnabled: true
            ) {
                onConnect(selectedConnection)
            })
        }

        if let activeTab {
            result.append(PaletteAction(
                title: "Reconnect Active Tab",
                subtitle: activeTab.profile.name,
                icon: "arrow.clockwise",
                isEnabled: true,
                run: onReconnectActive
            ))
            result.append(PaletteAction(
                title: "Close Active Tab",
                subtitle: activeTab.profile.name,
                icon: "xmark.circle",
                isEnabled: true,
                run: onCloseActive
            ))
        }

        result.append(PaletteAction(
            title: "Open Fleet Dashboard",
            subtitle: connectedHostCount >= 2 ? "\(connectedHostCount) connected SSH hosts" : "Connect at least two SSH hosts",
            icon: "square.grid.2x2",
            isEnabled: connectedHostCount >= 2,
            run: onOpenDashboard
        ))
        result.append(PaletteAction(title: "Toggle Sidebar", subtitle: "Show or hide connections", icon: "sidebar.left", run: onToggleSidebar))
        result.append(PaletteAction(title: "Toggle Bottom Panel", subtitle: "Logs, processes, services, and transfers", icon: "rectangle.bottomthird.inset.filled", run: onToggleBottom))
        result.append(PaletteAction(title: "Toggle Inspector", subtitle: "System monitor and server health", icon: "sidebar.right", run: onToggleInspector))
        result.append(PaletteAction(title: "Export Diagnostics", subtitle: "Create a redacted support bundle", icon: "square.and.arrow.up", run: onExportDiagnostics))

        for profile in connections.sorted(by: profileSort) {
            result.append(PaletteAction(
                title: "Connect: \(profile.name)",
                subtitle: "\(profile.username)@\(profile.host):\(profile.port)",
                icon: profile.kind.supportsTerminal ? "terminal" : "folder",
                isEnabled: true
            ) {
                onConnect(profile)
            })
        }

        return result
    }

    private var filteredActions: [PaletteAction] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return actions }
        let needle = trimmed.lowercased()
        return actions.filter {
            $0.title.lowercased().contains(needle)
                || $0.subtitle.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Run a command or connect to a server", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredActions) { action in
                        Button {
                            guard action.isEnabled else { return }
                            dismiss()
                            action.run()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: action.icon)
                                    .foregroundStyle(action.isEnabled ? Color.accentColor : Color.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(action.isEnabled ? .primary : .secondary)
                                    Text(action.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!action.isEnabled)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 560, height: 520)
    }

    private func profileSort(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        if lhs.favorite != rhs.favorite {
            return lhs.favorite && !rhs.favorite
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    var isEnabled = true
    let run: () -> Void
}

extension Notification.Name {
    static let showCommandPalette = Notification.Name("midnightSSHShowCommandPalette")
}

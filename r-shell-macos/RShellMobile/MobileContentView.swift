import SwiftUI
import UniformTypeIdentifiers

struct MobileContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var bridgeManager: MobileBridgeManager
    @EnvironmentObject private var keychainManager: MobileKeychainManager
    @EnvironmentObject private var connectionStore: MobileConnectionStore
    @EnvironmentObject private var sessionStore: MobileSessionStore
    @EnvironmentObject private var terminalPreferences: MobileTerminalPreferences
    @EnvironmentObject private var entitlementsStore: MobileEntitlementsStore

    @State private var selectedConnectionId: String?
    @State private var compactPath = NavigationPath()
    @State private var connectionSearch = ""
    @State private var editorTarget: MobileConnectionProfile?
    @State private var creatingConnection = false
    @State private var showingProUpgrade = false
    @State private var showingFleetDashboard = false
    @State private var showingSecurityVault = false
    @State private var showingCommandPalette = false
    @State private var exportingDiagnostics = false
    @State private var diagnosticsDocument = MobileDiagnosticsDocument()
    @State private var diagnosticsFilename = MobileDiagnosticsBundleFactory.defaultFilename()
    @State private var diagnosticsError: String?

    private var selectedConnection: MobileConnectionProfile? {
        guard let selectedConnectionId else { return connectionStore.connections.first }
        return connectionStore.connections.first { $0.id == selectedConnectionId }
    }

    private var filteredConnections: [MobileConnectionProfile] {
        let sorted = connectionStore.connections.sorted(by: connectionSort)
        let needle = connectionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { profile in
            connectionSearchFields(for: profile).contains { field in
                field.lowercased().contains(needle)
            }
        }
    }

    private var connectionGroups: [MobileConnectionFolderGroup] {
        let profiles = filteredConnections
        let hasFolders = profiles.contains { profile in
            profile.folder?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let grouped = Dictionary(grouping: profiles) { profile in
            guard hasFolders else { return "Connections" }
            return connectionFolderTitle(for: profile)
        }

        return grouped.keys
            .sorted(by: connectionFolderSort)
            .compactMap { title in
                guard let profiles = grouped[title] else { return nil }
                return MobileConnectionFolderGroup(title: title, profiles: profiles)
            }
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .sheet(isPresented: $creatingConnection) {
            MobileConnectionEditorView(profile: nil) { profile in
                connectionStore.upsert(profile)
                selectedConnectionId = profile.id
                if horizontalSizeClass == .compact {
                    compactPath = NavigationPath()
                    compactPath.append(profile.id)
                }
                creatingConnection = false
            } onCancel: {
                creatingConnection = false
            }
        }
        .sheet(isPresented: $showingProUpgrade) {
            MobileProUpgradeView(currentSavedHosts: connectionStore.connections.count)
        }
        .sheet(isPresented: $showingFleetDashboard) {
            MobileFleetDashboardView(profiles: connectionStore.connections)
        }
        .sheet(isPresented: $showingSecurityVault) {
            MobileSecurityVaultView(profiles: connectionStore.connections)
        }
        .sheet(isPresented: $showingCommandPalette) {
            MobileGlobalCommandPaletteView(
                profiles: connectionStore.connections,
                selectedProfileId: selectedConnectionId,
                onSelectProfile: { profile in
                    selectedConnectionId = profile.id
                    if horizontalSizeClass == .compact {
                        compactPath = NavigationPath()
                        compactPath.append(profile.id)
                    }
                },
                onAddConnection: {
                    beginCreateConnection()
                },
                onOpenFleet: {
                    showingFleetDashboard = true
                },
                onOpenSecurityVault: {
                    showingSecurityVault = true
                },
                onExportDiagnostics: {
                    exportDiagnostics()
                }
            )
        }
        .sheet(item: $editorTarget) { profile in
            MobileConnectionEditorView(profile: profile) { updated in
                connectionStore.upsert(updated)
                selectedConnectionId = updated.id
                editorTarget = nil
            } onCancel: {
                editorTarget = nil
            }
        }
        .alert(
            "Storage Error",
            isPresented: Binding(
                get: { connectionStore.lastError != nil },
                set: { if !$0 { connectionStore.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionStore.lastError ?? "")
        }
        .alert(
            "Credential Error",
            isPresented: Binding(
                get: { keychainManager.lastError != nil },
                set: { if !$0 { keychainManager.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(keychainManager.lastError ?? "")
        }
        .alert(
            "Diagnostics Export Failed",
            isPresented: Binding(
                get: { diagnosticsError != nil },
                set: { if !$0 { diagnosticsError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticsError ?? "")
        }
        .fileExporter(
            isPresented: $exportingDiagnostics,
            document: diagnosticsDocument,
            contentType: .json,
            defaultFilename: diagnosticsFilename
        ) { result in
            if case .failure(let error) = result {
                diagnosticsError = MobileDiagnosticsRedactor.redactSecrets(error.localizedDescription)
            }
        }
        .onAppear {
            bridgeManager.initialize()
        }
        .background {
            Button("Command Palette") {
                showingCommandPalette = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private var regularLayout: some View {
        NavigationSplitView {
            List(selection: $selectedConnectionId) {
                if connectionStore.connections.isEmpty {
                    ContentUnavailableView(
                        "No Connections",
                        systemImage: "server.rack",
                        description: Text("Add an SSH or SFTP profile to start testing the mobile bridge.")
                    )
                    .listRowSeparator(.hidden)
                } else if filteredConnections.isEmpty {
                    ContentUnavailableView(
                        "No Matches",
                        systemImage: "magnifyingglass",
                        description: Text("No saved connection matches this search.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(connectionGroups) { group in
                        Section(group.title) {
                            ForEach(group.profiles) { profile in
                                MobileConnectionRow(profile: profile)
                                    .tag(profile.id)
                                    .contextMenu {
                                        connectionContextMenu(for: profile)
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("midnight-ssh")
            .searchable(
                text: $connectionSearch,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search Connections"
            )
            .toolbar {
                connectionToolbar
            }
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            if let selectedConnection {
                MobileServerDetailView(profile: selectedConnection)
                    .id(selectedConnection.id)
            } else {
                ContentUnavailableView(
                    "Select a Connection",
                    systemImage: "terminal",
                    description: Text("The iPadOS workspace will show terminal, files, and server health here.")
                )
            }
        }
    }

    private var compactLayout: some View {
        NavigationStack(path: $compactPath) {
            List {
                if connectionStore.connections.isEmpty {
                    ContentUnavailableView(
                        "No Connections",
                        systemImage: "server.rack",
                        description: Text("Add an SSH or SFTP profile to start testing the mobile bridge.")
                    )
                    .listRowSeparator(.hidden)
                } else if filteredConnections.isEmpty {
                    ContentUnavailableView(
                        "No Matches",
                        systemImage: "magnifyingglass",
                        description: Text("No saved connection matches this search.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(connectionGroups) { group in
                        Section(group.title) {
                            ForEach(group.profiles) { profile in
                                NavigationLink(value: profile.id) {
                                    MobileConnectionRow(profile: profile)
                                }
                                .contextMenu {
                                    connectionContextMenu(for: profile)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("midnight-ssh")
            .searchable(
                text: $connectionSearch,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search Connections"
            )
            .toolbar {
                connectionToolbar
            }
            .navigationDestination(for: String.self) { profileId in
                if let profile = connectionStore.connections.first(where: { $0.id == profileId }) {
                    MobileServerDetailView(profile: profile)
                        .id(profile.id)
                } else {
                    ContentUnavailableView(
                        "Connection Removed",
                        systemImage: "trash",
                        description: Text("This saved connection is no longer available.")
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 6) {
            MobileConnectionLimitStatusView {
                showingProUpgrade = true
            }
            MobileBridgeStatusView()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var connectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button {
                    showingProUpgrade = true
                } label: {
                    Label(
                        entitlementsStore.isPro ? "Pro Active" : "Upgrade to Pro",
                        systemImage: entitlementsStore.isPro ? "checkmark.seal.fill" : "sparkles"
                    )
                }

                Button {
                    showingCommandPalette = true
                } label: {
                    Label("Command Palette", systemImage: "command")
                }

                Button {
                    showingFleetDashboard = true
                } label: {
                    Label("Fleet Dashboard", systemImage: "rectangle.grid.2x2")
                }

                Button {
                    showingSecurityVault = true
                } label: {
                    Label("Security Vault", systemImage: "lock.shield")
                }

                Button {
                    exportDiagnostics()
                } label: {
                    Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More actions")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                beginCreateConnection()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add connection")
        }
    }

    @ViewBuilder
    private func connectionContextMenu(for profile: MobileConnectionProfile) -> some View {
        if case .connected = sessionStore.status(for: profile) {
            Button("Disconnect", role: .destructive) {
                sessionStore.disconnect(profile: profile)
            }
        }
        Button("Edit") { editorTarget = profile }
        Button("Delete", role: .destructive) {
            connectionStore.delete(profile)
        }
    }

    @MainActor
    private func exportDiagnostics() {
        do {
            let bundle = MobileDiagnosticsBundleFactory.make(
                bridgeManager: bridgeManager,
                keychainManager: keychainManager,
                connectionStore: connectionStore,
                sessionStore: sessionStore,
                terminalPreferences: terminalPreferences,
                entitlementsStore: entitlementsStore
            )
            diagnosticsDocument = MobileDiagnosticsDocument(
                data: try MobileDiagnosticsBundleFactory.encode(bundle)
            )
            diagnosticsFilename = MobileDiagnosticsBundleFactory.defaultFilename(
                generatedAt: bundle.generatedAt
            )
            exportingDiagnostics = true
        } catch {
            diagnosticsError = MobileDiagnosticsRedactor.redactSecrets(error.localizedDescription)
        }
    }

    private func beginCreateConnection() {
        if entitlementsStore.canCreateConnection(currentCount: connectionStore.connections.count) {
            creatingConnection = true
        } else {
            showingProUpgrade = true
        }
    }

    private func connectionSort(_ lhs: MobileConnectionProfile, _ rhs: MobileConnectionProfile) -> Bool {
        if lhs.favorite != rhs.favorite {
            return lhs.favorite && !rhs.favorite
        }

        let lhsFolder = connectionFolderTitle(for: lhs)
        let rhsFolder = connectionFolderTitle(for: rhs)
        if lhsFolder != rhsFolder {
            return connectionFolderSort(lhsFolder, rhsFolder)
        }

        let nameCompare = lhs.name.localizedStandardCompare(rhs.name)
        if nameCompare != .orderedSame {
            return nameCompare == .orderedAscending
        }

        return lhs.host.localizedStandardCompare(rhs.host) == .orderedAscending
    }

    private func connectionFolderTitle(for profile: MobileConnectionProfile) -> String {
        let folder = profile.folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return folder.isEmpty ? "Unfiled" : folder
    }

    private func connectionFolderSort(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "Unfiled" { return false }
        if rhs == "Unfiled" { return true }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private func connectionSearchFields(for profile: MobileConnectionProfile) -> [String] {
        [
            profile.name,
            profile.host,
            profile.username,
            "\(profile.port)",
            profile.kind.rawValue,
            profile.kind.displayName,
            profile.authMethod.rawValue,
            profile.authMethod.displayName,
            profile.folder ?? "",
            profile.tags.joined(separator: " "),
            profile.notes ?? ""
        ]
    }
}

private struct MobileConnectionFolderGroup: Identifiable {
    let title: String
    let profiles: [MobileConnectionProfile]

    var id: String { title }
}

private struct MobileConnectionRow: View {
    @EnvironmentObject private var sessionStore: MobileSessionStore

    let profile: MobileConnectionProfile

    private var status: MobileSessionStatus {
        sessionStore.status(for: profile)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: profile.kind.supportsTerminal ? "terminal" : "folder")
                .foregroundStyle(profile.kind.supportsTerminal ? .green : .blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(profile.username)@\(profile.host):\(profile.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if profile.favorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }

            if case .connected = status {
                Button {
                    sessionStore.disconnect(profile: profile)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Disconnect \(profile.name)")
            }

            MobileSessionStatusDot(status: status)
        }
        .padding(.vertical, 4)
    }
}

private struct MobileSessionStatusDot: View {
    let status: MobileSessionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .accessibilityLabel(status.label)
    }

    private var color: Color {
        switch status {
        case .disconnected:
            return .secondary
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct MobileConnectionLimitStatusView: View {
    @EnvironmentObject private var connectionStore: MobileConnectionStore
    @EnvironmentObject private var entitlementsStore: MobileEntitlementsStore

    let onUpgrade: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entitlementsStore.isPro ? "checkmark.seal.fill" : "server.rack")
                .font(.caption)
                .foregroundStyle(entitlementsStore.isPro ? .green : .secondary)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if !entitlementsStore.isPro {
                Button("Pro") {
                    onUpgrade()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .disabled(entitlementsStore.status.isBusy)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
    }

    private var statusText: String {
        if entitlementsStore.isPro {
            return "Pro active"
        }

        return "Saved hosts \(connectionStore.connections.count)/\(MobileEntitlementsStore.freeSavedHostLimit)"
    }
}

private struct MobileBridgeStatusView: View {
    @EnvironmentObject private var bridgeManager: MobileBridgeManager

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(bridgeManager.initialized ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Text(bridgeManager.initialized ? "Rust bridge ready" : "Initializing bridge")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let initializationError = bridgeManager.initializationError {
                Text(initializationError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}

import SwiftUI
import UIKit

struct MobileServerDetailView: View {
    @EnvironmentObject private var connectionStore: MobileConnectionStore
    @EnvironmentObject private var keychainManager: MobileKeychainManager
    @EnvironmentObject private var sessionStore: MobileSessionStore

    let profile: MobileConnectionProfile

    @State private var hasStoredCredential = false
    @State private var credentialMessage: String?
    @State private var resolvingCredential = false
    @State private var quickActionRunningId: String?
    @State private var quickActionResult: MobileQuickActionResult?
    @State private var publicKeyCopied = false

    private var status: MobileSessionStatus {
        sessionStore.status(for: profile)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionStatusBanner
                    dashboardSection
                        .id(MobileServerDetailSection.dashboard)
                    snippetsSection
                        .id(MobileServerDetailSection.snippets)
                    terminalSection
                        .id(MobileServerDetailSection.terminal)
                    fileBrowserSection
                        .id(MobileServerDetailSection.files)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                quickActionsToolbar(scrollProxy: scrollProxy)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .sheet(item: $quickActionResult) { result in
            MobileQuickActionResultView(result: result)
        }
        .alert(
            "Connection Needs Attention",
            isPresented: Binding(
                get: { credentialMessage != nil },
                set: { if !$0 { credentialMessage = nil } }
            )
        ) {
            if let publicKey = failedPublicKey {
                Button("Copy Public Key") {
                    copyPublicKey(publicKey)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionAttentionMessage)
        }
        .onAppear {
            refreshStoredCredentialState()
        }
        .onChange(of: keychainManager.credentialRevision) { _, _ in
            refreshStoredCredentialState()
        }
    }

    private func quickActionsToolbar(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    toolbarActionButton(
                        title: isConnected ? "Reconnect" : "Connect",
                        systemImage: isConnected ? "arrow.clockwise" : "bolt.horizontal.fill",
                        tint: isConnected ? .orange : .green,
                        isDisabled: status.isBusy || resolvingCredential || quickActionRunningId != nil
                    ) {
                        Task { await connectOrReconnectFromQuickAction() }
                    }

                    if case .connected(let connectionId) = status {
                        toolbarActionButton(
                            title: "Tail Logs",
                            systemImage: "doc.text.magnifyingglass",
                            tint: .orange,
                            isDisabled: quickActionRunningId != nil
                        ) {
                            Task { await tailLogs(connectionId: connectionId) }
                        }

                        toolbarActionButton(title: "Snippets", systemImage: "command", tint: .purple) {
                            scroll(to: .snippets, with: scrollProxy)
                        }

                        if profile.kind.supportsTerminal {
                            toolbarActionButton(title: "Terminal", systemImage: "terminal", tint: .green) {
                                scroll(to: .terminal, with: scrollProxy)
                            }
                        }

                        toolbarActionButton(title: "Files", systemImage: "folder", tint: .blue) {
                            scroll(to: .files, with: scrollProxy)
                        }

                        toolbarActionButton(title: "Dashboard", systemImage: "chart.xyaxis.line", tint: .cyan) {
                            scroll(to: .dashboard, with: scrollProxy)
                        }
                    }

                    if quickActionRunningId != nil {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            Divider()
        }
        .background(.bar)
    }

    private func toolbarActionButton(
        title: String,
        systemImage: String,
        tint: Color,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
        }
        .buttonStyle(.bordered)
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var snippetsSection: some View {
        if case .connected(let connectionId) = status {
            MobileSnippetsView(
                connectionId: connectionId,
                profileName: profile.name
            )
        }
    }

    private var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    @ViewBuilder
    private var connectionStatusBanner: some View {
        if let failureMessage = status.failureMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label("Connection failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(failureMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let publicKey = failedPublicKey {
                    failedPublicKeyView(publicKey)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var failedPublicKey: String? {
        guard status.failureMessage != nil,
              profile.authMethod == .publicKey,
              let publicKey = MobileSSHKeyVault.shared.metadata(for: profile.sshKeyReference)?.publicKey else {
            return nil
        }
        let trimmed = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var connectionAttentionMessage: String {
        let message = credentialMessage ?? ""
        guard let publicKey = failedPublicKey else { return message }
        return "\(message)\n\nPublic key:\n\(publicKey)"
    }

    private func failedPublicKeyView(_ publicKey: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Public key")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(publicKey)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

            Button {
                copyPublicKey(publicKey)
            } label: {
                Label(
                    publicKeyCopied ? "Copied" : "Copy to Clipboard",
                    systemImage: publicKeyCopied ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(publicKeyCopied ? .green : nil)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var terminalSection: some View {
        if profile.kind.supportsTerminal,
           case .connected(let connectionId) = status {
            MobileTerminalPane(
                connectionId: connectionId,
                profileName: profile.name
            )
        }
    }

    @ViewBuilder
    private var dashboardSection: some View {
        if case .connected(let connectionId) = status {
            MobileServerDashboardView(
                connectionId: connectionId,
                profileName: profile.name,
                sshPort: profile.port
            )
        }
    }

    @ViewBuilder
    private var fileBrowserSection: some View {
        if case .connected(let connectionId) = status {
            MobileFileBrowserView(
                connectionId: connectionId,
                profileName: profile.name
            )
        }
    }

    private var credentialKind: MobileCredentialKind {
        profile.authMethod == .password ? .sshPassword : .sshKeyPassphrase
    }

    private func connect() async {
        credentialMessage = nil

        let resolvedPassword: String?
        let resolvedPassphrase: String?

        switch profile.authMethod {
        case .password:
            let hasPassword = keychainManager.hasSecret(
                kind: .sshPassword,
                account: profile.keychainAccount
            )
            hasStoredCredential = hasPassword
            guard hasPassword else {
                credentialMessage = "Edit this connection and save a password before connecting."
                return
            }
            resolvingCredential = true
            defer { resolvingCredential = false }
            resolvedPassword = await keychainManager.loadSecret(
                kind: .sshPassword,
                account: profile.keychainAccount,
                reason: "Unlock the saved password for \(profile.name)."
            )
            guard resolvedPassword != nil else {
                credentialMessage = "Could not unlock the saved password."
                return
            }
            resolvedPassphrase = nil

        case .publicKey:
            guard profile.sshKeyReference != nil else {
                credentialMessage = "Edit this connection and generate or import an SSH key before connecting."
                return
            }
            resolvedPassword = nil
            let hasPassphrase = keychainManager.hasSecret(
                kind: .sshKeyPassphrase,
                account: profile.keychainAccount
            )
            hasStoredCredential = hasPassphrase
            if hasPassphrase {
                resolvingCredential = true
                defer { resolvingCredential = false }
                resolvedPassphrase = await keychainManager.loadSecret(
                    kind: .sshKeyPassphrase,
                    account: profile.keychainAccount,
                    reason: "Unlock the saved key passphrase for \(profile.name)."
                )
                guard resolvedPassphrase != nil else {
                    credentialMessage = "Could not unlock the saved passphrase."
                    return
                }
            } else {
                resolvedPassphrase = nil
            }
        }

        sessionStore.connect(
            profile: profile,
            password: resolvedPassword,
            passphrase: resolvedPassphrase,
            onSuccess: {
                connectionStore.markConnected(profile)
                refreshStoredCredentialState()
            },
            onFailure: { message in
                credentialMessage = message
            }
        )
    }

    private func connectOrReconnectFromQuickAction() async {
        if isConnected {
            sessionStore.disconnect(profile: profile)
        }
        await connect()
    }

    @MainActor
    private func tailLogs(connectionId: String) async {
        guard quickActionRunningId == nil else { return }

        quickActionRunningId = "tail-logs"
        defer { quickActionRunningId = nil }

        let command = """
        set +e
        if command -v journalctl >/dev/null 2>&1; then
          journalctl -n 160 --no-pager -o short-iso 2>&1
        elif [ -r /var/log/syslog ]; then
          tail -n 160 /var/log/syslog
        elif [ -r /var/log/system.log ]; then
          tail -n 160 /var/log/system.log
        else
          echo "No readable journalctl, /var/log/syslog, or /var/log/system.log source found."
        fi
        """

        do {
            let output = try await MobileMonitorBridge.shared.executeCommand(
                connectionId: connectionId,
                command: command
            )
            quickActionResult = MobileQuickActionResult(
                title: "Recent Logs",
                command: command,
                output: output.isEmpty ? "(no output)" : output,
                error: nil
            )
        } catch {
            quickActionResult = MobileQuickActionResult(
                title: "Recent Logs",
                command: command,
                output: "",
                error: error.localizedDescription
            )
        }
    }

    private func scroll(to section: MobileServerDetailSection, with scrollProxy: ScrollViewProxy) {
        withAnimation(.snappy) {
            scrollProxy.scrollTo(section, anchor: .top)
        }
    }

    private func copyPublicKey(_ publicKey: String) {
        UIPasteboard.general.string = publicKey
        publicKeyCopied = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            publicKeyCopied = false
        }
    }

    private func refreshStoredCredentialState() {
        hasStoredCredential = keychainManager.hasSecret(
            kind: credentialKind,
            account: profile.keychainAccount
        )
    }
}

private enum MobileServerDetailSection: Hashable {
    case dashboard
    case snippets
    case terminal
    case files
}

private struct MobileQuickActionResult: Identifiable {
    let id = UUID()
    let title: String
    let command: String
    let output: String
    let error: String?
}

private struct MobileQuickActionResultView: View {
    let result: MobileQuickActionResult

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                if let error = result.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(result.command)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(5)
                }

                ScrollView {
                    Text(result.output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding()
            .navigationTitle(result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

import SwiftUI
import UIKit

struct MobileServerDetailView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var detailMode: MobileServerDetailMode = .inspect
    @State private var showingKeyboardShortcuts = false
    @State private var wasBackgroundedWhileConnected = false
    @State private var showingResumeBanner = false

    private var status: MobileSessionStatus {
        sessionStore.status(for: profile)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modePicker
                    compactIncidentBanner
                    resumeBanner
                    connectionStatusBanner
                    switch detailMode {
                    case .inspect:
                        MobileConnectionConfidenceView(profile: profile, status: status)
                        activitySection
                        dashboardSection
                            .id(MobileServerDetailSection.dashboard)
                    case .work:
                        snippetsSection
                            .id(MobileServerDetailSection.snippets)
                        sessionResilienceCard
                        terminalSection
                            .id(MobileServerDetailSection.terminal)
                        fileBrowserSection
                            .id(MobileServerDetailSection.files)
                    }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingKeyboardShortcuts = true
                } label: {
                    Image(systemName: "keyboard")
                }
                .accessibilityLabel("Keyboard shortcuts")
            }
        }
        .background(keyboardShortcutLayer)
        .sheet(item: $quickActionResult) { result in
            MobileQuickActionResultView(result: result)
        }
        .sheet(isPresented: $showingKeyboardShortcuts) {
            MobileKeyboardShortcutsSheet()
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
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $detailMode) {
            Label("Inspect", systemImage: "chart.xyaxis.line").tag(MobileServerDetailMode.inspect)
            Label("Work", systemImage: "terminal").tag(MobileServerDetailMode.work)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var compactIncidentBanner: some View {
        if horizontalSizeClass == .compact {
            VStack(alignment: .leading, spacing: 10) {
                Label("Incident Mode", systemImage: "bolt.horizontal.circle")
                    .font(.headline)
                HStack(spacing: 8) {
                    Button {
                        detailMode = .inspect
                    } label: {
                        Label("Doctor", systemImage: "stethoscope")
                    }
                    .buttonStyle(.bordered)

                    if case .connected(let connectionId) = status {
                        Button {
                            Task { await tailLogs(connectionId: connectionId) }
                        } label: {
                            Label("Logs", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            detailMode = .work
                        } label: {
                            Label("Files", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            Task { await connectOrReconnectFromQuickAction() }
                        } label: {
                            Label("Connect", systemImage: "bolt.horizontal.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.small)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var resumeBanner: some View {
        if showingResumeBanner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "ipad.and.arrow.forward")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session resumed")
                        .font(.subheadline.weight(.semibold))
                    Text("iPadOS may suspend sockets while the app is in the background. Reconnect if the terminal or file browser feels stale.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reconnect") {
                    showingResumeBanner = false
                    Task { await connectOrReconnectFromQuickAction() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    showingResumeBanner = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
            }
            .padding()
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var sessionResilienceCard: some View {
        if profile.kind.supportsTerminal {
            VStack(alignment: .leading, spacing: 8) {
                Label("Resilient Sessions", systemImage: "rectangle.connected.to.line.below")
                    .font(.headline)
                Text("For long-running commands from iPad, use tmux or screen on the server so work survives app backgrounding and network changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button {
                        UIPasteboard.general.string = "tmux new -As midnight"
                    } label: {
                        Label("Copy tmux attach", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        UIPasteboard.general.string = "screen -R midnight"
                    } label: {
                        Label("Copy screen attach", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var keyboardShortcutLayer: some View {
        Group {
            Button("Inspect Mode") {
                detailMode = .inspect
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Work Mode") {
                detailMode = .work
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Reconnect") {
                Task { await connectOrReconnectFromQuickAction() }
            }
            .keyboardShortcut("r", modifiers: .command)

            if case .connected(let connectionId) = status {
                Button("Tail Logs") {
                    Task { await tailLogs(connectionId: connectionId) }
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
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
    private var activitySection: some View {
        switch status {
        case .connected(let connectionId):
            MobileActivityTimelineView(
                profileId: profile.id,
                connectionId: connectionId,
                maxEvents: 6
            )
        default:
            MobileActivityTimelineView(
                profileId: profile.id,
                connectionId: nil,
                maxEvents: 6
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
        detailMode = section.mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.snappy) {
                scrollProxy.scrollTo(section, anchor: .top)
            }
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

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if wasBackgroundedWhileConnected {
                showingResumeBanner = true
                wasBackgroundedWhileConnected = false
            }
        case .background, .inactive:
            wasBackgroundedWhileConnected = isConnected
        @unknown default:
            break
        }
    }
}

private enum MobileServerDetailSection: Hashable {
    case dashboard
    case snippets
    case terminal
    case files

    var mode: MobileServerDetailMode {
        switch self {
        case .dashboard:
            return .inspect
        case .snippets, .terminal, .files:
            return .work
        }
    }
}

private enum MobileServerDetailMode: String, Hashable {
    case inspect
    case work
}

private struct MobileQuickActionResult: Identifiable {
    let id = UUID()
    let title: String
    let command: String
    let output: String
    let error: String?
}

private struct MobileKeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                shortcut("Inspect mode", keys: "⌘1")
                shortcut("Work mode", keys: "⌘2")
                shortcut("Reconnect", keys: "⌘R")
                shortcut("Tail logs", keys: "⌘L")
            }
            .navigationTitle("Keyboard Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
    }
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

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
    @State private var splitFraction = 0.55
    @State private var showingConfidence = false

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
                        connectionConfidenceTrigger
                        activitySection
                        dashboardSection
                            .id(MobileServerDetailSection.dashboard)
                    case .work:
                        snippetsSection
                            .id(MobileServerDetailSection.snippets)
                        sessionResilienceCard
                        if horizontalSizeClass != .compact {
                            splitWorkPane
                        } else {
                            terminalSection
                                .id(MobileServerDetailSection.terminal)
                            fileBrowserSection
                                .id(MobileServerDetailSection.files)
                        }
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
        .sheet(isPresented: $showingConfidence) {
            MobileConnectionConfidenceSheet(profile: profile, status: status)
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

    private var splitWorkPane: some View {
        VStack(spacing: 0) {
            terminalSection
                .id(MobileServerDetailSection.terminal)
                .frame(height: UIScreen.main.bounds.height * splitFraction * 0.75)
                .clipped()

            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
                .overlay(alignment: .center) {
                    HStack(spacing: 10) {
                        Button {
                            splitFraction = min(0.8, splitFraction + 0.1)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .opacity(0.6)

                        Rectangle()
                            .fill(Color(.separator))
                            .frame(width: 40, height: 4)
                            .clipShape(RoundedRectangle(cornerRadius: 2))

                        Button {
                            splitFraction = max(0.2, splitFraction - 0.1)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .opacity(0.6)
                    }
                    .padding(.vertical, 4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let totalHeight = UIScreen.main.bounds.height * 0.75
                            let newFraction = splitFraction + value.translation.height / totalHeight
                            splitFraction = min(0.8, max(0.2, newFraction))
                        }
                )

            fileBrowserSection
                .id(MobileServerDetailSection.files)
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

    private var connectionConfidenceTrigger: some View {
        Button {
            showingConfidence = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection Confidence")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(profile.username)@\(profile.host):\(profile.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                confidenceStatusPill
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection confidence details")
    }

    private var confidenceStatusPill: some View {
        let state: (label: String, color: Color) = {
            switch status {
            case .connected:    return ("Connected", .green)
            case .connecting:   return ("Connecting", .orange)
            case .disconnected: return ("Disconnected", .secondary)
            case .failed:       return ("Needs attention", .red)
            }
        }()
        return HStack(spacing: 5) {
            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
            Text(state.label)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(state.color.opacity(0.12), in: Capsule())
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
                error: nil,
                isLog: true
            )
        } catch {
            quickActionResult = MobileQuickActionResult(
                title: "Recent Logs",
                command: command,
                output: "",
                error: error.localizedDescription,
                isLog: true
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
                wasBackgroundedWhileConnected = false
                if isConnected {
                    showingResumeBanner = true
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await silentReconnect()
                    }
                }
            }
        case .background, .inactive:
            wasBackgroundedWhileConnected = isConnected
        @unknown default:
            break
        }
    }

    private func silentReconnect() async {
        guard isConnected else { return }
        sessionStore.disconnect(profile: profile)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await connect()
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
    var isLog: Bool = false
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

                if result.isLog {
                    MobileJournalLogView(rawOutput: result.output)
                } else {
                    ScrollView {
                        Text(result.output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
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

private struct MobileConnectionConfidenceSheet: View {
    let profile: MobileConnectionProfile
    let status: MobileSessionStatus

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MobileConnectionConfidenceView(profile: profile, status: status)
                    .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Connection Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Journal log view

private enum MobileJournalSeverity: String, CaseIterable, Hashable, Identifiable {
    case error
    case warn
    case info
    case debug

    var id: String { rawValue }

    var label: String {
        switch self {
        case .error: return "Errors"
        case .warn:  return "Warnings"
        case .info:  return "Info"
        case .debug: return "Debug"
        }
    }

    var symbol: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warn:  return "exclamationmark.triangle.fill"
        case .info:  return "circle.fill"
        case .debug: return "ladybug.fill"
        }
    }

    var color: Color {
        switch self {
        case .error: return .red
        case .warn:  return .orange
        case .info:  return .secondary
        case .debug: return .secondary
        }
    }
}

private struct MobileJournalLine: Identifiable {
    let id: Int
    let timestamp: String?
    let prefix: String
    let message: String
    let severity: MobileJournalSeverity
    let raw: String

    static func parseAll(_ rawLines: [String]) -> [MobileJournalLine] {
        rawLines.enumerated().map { idx, raw in parse(raw: raw, id: idx) }
    }

    private static func parse(raw: String, id: Int) -> MobileJournalLine {
        let chars = Array(raw)
        let isShortIso = chars.count >= 19
            && chars[4] == "-" && chars[7] == "-" && chars[10] == "T"
            && chars[13] == ":" && chars[16] == ":"

        var timestamp: String? = nil
        var prefix = ""
        var message = raw

        if isShortIso, let firstSpace = raw.firstIndex(of: " ") {
            let isoPart = raw[..<firstSpace]
            timestamp = formatTimestamp(String(isoPart))
            let rest = String(raw[raw.index(after: firstSpace)...])
            if let colonRange = rest.range(of: ": ") {
                prefix = String(rest[..<colonRange.lowerBound])
                message = String(rest[colonRange.upperBound...])
            } else {
                message = rest
            }
        }

        return MobileJournalLine(
            id: id,
            timestamp: timestamp,
            prefix: prefix,
            message: message,
            severity: severity(for: message),
            raw: raw
        )
    }

    private static func formatTimestamp(_ iso: String) -> String {
        guard let tIndex = iso.firstIndex(of: "T") else { return iso }
        let timePart = iso[iso.index(after: tIndex)...]
        let stopIdx = timePart.firstIndex { $0 == "+" || $0 == "-" || $0 == "Z" || $0 == "." }
        if let stopIdx { return String(timePart[..<stopIdx]) }
        return String(timePart)
    }

    private static let errorRegex = try? NSRegularExpression(
        pattern: #"\b(error|errors|fatal|panic|crit|critical|emerg|alert|denied|fail|failed|failure)\b"#,
        options: [.caseInsensitive]
    )
    private static let warnRegex = try? NSRegularExpression(
        pattern: #"\b(warn|warning|deprecated|timeout|timed\s*out|retry|retrying|deferred|refused|rejected)\b"#,
        options: [.caseInsensitive]
    )
    private static let debugRegex = try? NSRegularExpression(
        pattern: #"\b(debug|trace)\b"#,
        options: [.caseInsensitive]
    )

    private static func severity(for message: String) -> MobileJournalSeverity {
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        if errorRegex?.firstMatch(in: message, range: range) != nil { return .error }
        if warnRegex?.firstMatch(in: message, range: range) != nil { return .warn }
        if debugRegex?.firstMatch(in: message, range: range) != nil { return .debug }
        return .info
    }

    private static let ipv4Regex = try? NSRegularExpression(
        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"#
    )

    var extractedIPv4: String? {
        guard let regex = MobileJournalLine.ipv4Regex else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              let r = Range(match.range, in: message) else { return nil }
        return String(message[r])
    }
}

struct MobileJournalLogView: View {
    let rawOutput: String

    @State private var searchText = ""
    @State private var enabledSeverities: Set<MobileJournalSeverity> = Set(MobileJournalSeverity.allCases)
    @State private var pinnedIDs: Set<Int> = []
    @State private var jumpCursor: Int?
    @State private var showShare = false

    private var rawLines: [String] {
        rawOutput
            .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private var lines: [MobileJournalLine] { MobileJournalLine.parseAll(rawLines) }

    private var counts: [MobileJournalSeverity: Int] {
        var c: [MobileJournalSeverity: Int] = [:]
        for line in lines { c[line.severity, default: 0] += 1 }
        return c
    }

    private var filtered: [MobileJournalLine] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lines.filter { line in
            guard enabledSeverities.contains(line.severity) else { return false }
            if needle.isEmpty { return true }
            return line.raw.lowercased().contains(needle)
        }
    }

    private var pinnedLines: [MobileJournalLine] {
        lines.filter { pinnedIDs.contains($0.id) }
    }

    private var issueIDs: [Int] {
        filtered
            .filter { $0.severity == .error || $0.severity == .warn }
            .map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            severityPills
            searchField
            if filtered.isEmpty && pinnedLines.isEmpty {
                placeholder
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !pinnedLines.isEmpty {
                                pinnedSection
                            }
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, line in
                                row(line, isPinned: pinnedIDs.contains(line.id))
                                    .id(line.id)
                                if index < filtered.count - 1 {
                                    Divider().opacity(0.18)
                                }
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: jumpCursor) { newValue in
                        guard let target = newValue else { return }
                        withAnimation(.snappy) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showShare) {
            MobileJournalShareSheet(text: filtered.map(\.raw).joined(separator: "\n"))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Journal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("(\(filtered.count) of \(lines.count))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            issueNavigator
            exportMenu
        }
    }

    @ViewBuilder
    private var issueNavigator: some View {
        if !issueIDs.isEmpty {
            HStack(spacing: 4) {
                Button {
                    jumpToIssue(forward: false)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous issue")

                Text("\(issueIDs.count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.orange)

                Button {
                    jumpToIssue(forward: true)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next issue")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(Color.orange.opacity(0.30), lineWidth: 0.5))
        }
    }

    private var exportMenu: some View {
        Menu {
            Button {
                copyFiltered()
            } label: {
                Label("Copy filtered (\(filtered.count) lines)", systemImage: "doc.on.doc")
            }
            .disabled(filtered.isEmpty)

            Button {
                copyAll()
            } label: {
                Label("Copy all (\(lines.count) lines)", systemImage: "doc.on.doc.fill")
            }
            .disabled(lines.isEmpty)

            Divider()

            Button {
                showShare = true
            } label: {
                Label("Share filtered…", systemImage: "square.and.arrow.up")
            }
            .disabled(filtered.isEmpty)

            if !pinnedIDs.isEmpty {
                Divider()
                Button(role: .destructive) {
                    pinnedIDs.removeAll()
                } label: {
                    Label("Unpin all (\(pinnedIDs.count))", systemImage: "pin.slash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.caption.weight(.semibold))
        }
        .accessibilityLabel("Journal options")
    }

    private var severityPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MobileJournalSeverity.allCases) { severity in
                    let count = counts[severity] ?? 0
                    let isOn = enabledSeverities.contains(severity)
                    Button {
                        toggle(severity)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: severity.symbol)
                                .font(.caption2)
                                .foregroundStyle(isOn ? severity.color : .secondary)
                            Text("\(count)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(isOn ? severity.color : .secondary)
                            Text(severity.label)
                                .font(.caption2)
                                .foregroundStyle(isOn ? severity.color : .secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            (isOn ? severity.color.opacity(0.14) : Color.gray.opacity(0.10)),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(
                                isOn ? severity.color.opacity(0.35) : Color.clear,
                                lineWidth: 0.5
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(severity.label), \(count) entries, \(isOn ? "filter on" : "filter off")")
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.caption)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Pinned section

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text("Pinned (\(pinnedLines.count))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ForEach(Array(pinnedLines.enumerated()), id: \.element.id) { index, line in
                row(line, isPinned: true)
                if index < pinnedLines.count - 1 {
                    Divider().opacity(0.18)
                }
            }
            Divider()
                .overlay(Color.yellow.opacity(0.40))
        }
        .background(Color.yellow.opacity(0.08))
    }

    // MARK: Placeholder

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: lines.isEmpty ? "tray" : "text.magnifyingglass")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(placeholderText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var placeholderText: String {
        if lines.isEmpty { return "No journal entries." }
        if !searchText.isEmpty { return "No matches for \"\(searchText)\"." }
        return "All severities are filtered out — re-enable one above."
    }

    // MARK: Row

    private func row(_ line: MobileJournalLine, isPinned: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                togglePin(line.id)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.caption2)
                    .foregroundStyle(isPinned ? Color.yellow : Color.gray.opacity(0.35))
            }
            .buttonStyle(.plain)
            .frame(width: 14, alignment: .center)
            .padding(.top, 3)
            .accessibilityLabel(isPinned ? "Unpin line" : "Pin line")

            Image(systemName: line.severity.symbol)
                .font(.caption2)
                .foregroundStyle(line.severity.color)
                .frame(width: 12, alignment: .center)
                .padding(.top, 3)

            if let timestamp = line.timestamp {
                Text(timestamp)
                    .font(.system(.caption2, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 56, alignment: .leading)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 1) {
                if !line.prefix.isEmpty {
                    Text(line.prefix)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(highlightedMessage(line.message))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(messageColor(for: line.severity))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(jumpCursor == line.id ? Color.accentColor.opacity(0.14) : Color.clear)
        .contextMenu {
            Button(isPinned ? "Unpin line" : "Pin line") {
                togglePin(line.id)
            }
            Button("Copy line") {
                UIPasteboard.general.string = line.raw
            }
            if let ip = line.extractedIPv4 {
                Button("Copy IP \(ip)") {
                    UIPasteboard.general.string = ip
                }
            }
            if let timestamp = line.timestamp {
                Button("Copy timestamp \(timestamp)") {
                    UIPasteboard.general.string = timestamp
                }
            }
        }
    }

    private func messageColor(for severity: MobileJournalSeverity) -> Color {
        switch severity {
        case .error, .warn: return severity.color
        case .info:         return .primary
        case .debug:        return .secondary
        }
    }

    private func highlightedMessage(_ message: String) -> AttributedString {
        var attributed = AttributedString(message)
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let found = attributed[searchRange].range(of: needle, options: .caseInsensitive) {
            attributed[found].backgroundColor = Color.yellow.opacity(0.45)
            attributed[found].foregroundColor = Color.black
            searchRange = found.upperBound..<attributed.endIndex
        }
        return attributed
    }

    // MARK: Actions

    private func toggle(_ severity: MobileJournalSeverity) {
        if enabledSeverities.contains(severity) {
            if enabledSeverities.count == 1 {
                enabledSeverities = Set(MobileJournalSeverity.allCases)
            } else {
                enabledSeverities.remove(severity)
            }
        } else {
            enabledSeverities.insert(severity)
        }
    }

    private func togglePin(_ id: Int) {
        if pinnedIDs.contains(id) {
            pinnedIDs.remove(id)
        } else {
            pinnedIDs.insert(id)
        }
    }

    private func jumpToIssue(forward: Bool) {
        guard !issueIDs.isEmpty else { return }
        if let cursor = jumpCursor, let idx = issueIDs.firstIndex(of: cursor) {
            let next = forward
                ? (idx + 1) % issueIDs.count
                : (idx - 1 + issueIDs.count) % issueIDs.count
            jumpCursor = issueIDs[next]
        } else {
            jumpCursor = forward ? issueIDs.first : issueIDs.last
        }
    }

    private func copyFiltered() {
        UIPasteboard.general.string = filtered.map(\.raw).joined(separator: "\n")
    }

    private func copyAll() {
        UIPasteboard.general.string = lines.map(\.raw).joined(separator: "\n")
    }
}

private struct MobileJournalShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

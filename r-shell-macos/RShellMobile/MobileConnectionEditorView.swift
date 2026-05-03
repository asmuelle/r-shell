import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MobileConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var keychainManager: MobileKeychainManager

    let profile: MobileConnectionProfile?
    let onSave: (MobileConnectionProfile) -> Void
    let onCancel: () -> Void
    private let originalSSHKeyReference: MobileSSHKeyReference?

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authMethod: MobileAuthMethod
    @State private var kind: MobileConnectionKind
    @State private var sshKeyReference: MobileSSHKeyReference?
    @State private var password: String
    @State private var passphrase: String
    @State private var saveCredential: Bool
    @State private var hasStoredCredential = false
    @State private var showingPrivateKeyImporter = false
    @State private var keyMessage: String?
    @State private var keyError: String?
    @State private var generatedPublicKey: String
    @State private var publicKeyCopied = false
    @State private var pendingKeyReferences: Set<MobileSSHKeyReference> = []
    @State private var keySetupRunning = false
    @State private var favorite: Bool
    @State private var folder: String
    @State private var tagsText: String
    @State private var notes: String

    init(
        profile: MobileConnectionProfile?,
        onSave: @escaping (MobileConnectionProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.profile = profile
        self.onSave = onSave
        self.onCancel = onCancel
        self.originalSSHKeyReference = profile?.sshKeyReference

        _name = State(initialValue: profile?.name ?? "")
        _host = State(initialValue: profile?.host ?? "")
        _port = State(initialValue: String(profile?.port ?? 22))
        _username = State(initialValue: profile?.username ?? "")
        _authMethod = State(initialValue: profile?.authMethod ?? .password)
        _kind = State(initialValue: profile?.kind ?? .ssh)
        _sshKeyReference = State(initialValue: profile?.sshKeyReference)
        _password = State(initialValue: "")
        _passphrase = State(initialValue: "")
        _saveCredential = State(initialValue: true)
        _generatedPublicKey = State(initialValue: MobileSSHKeyVault.shared.metadata(for: profile?.sshKeyReference)?.publicKey ?? "")
        _favorite = State(initialValue: profile?.favorite ?? false)
        _folder = State(initialValue: profile?.folder ?? "")
        _tagsText = State(initialValue: profile?.tags.joined(separator: ", ") ?? "")
        _notes = State(initialValue: profile?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Connection") {
                    Picker("Kind", selection: $kind) {
                        ForEach(MobileConnectionKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }

                    Picker("Authentication", selection: $authMethod) {
                        ForEach(MobileAuthMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }

                    if authMethod == .publicKey {
                        privateKeyControls
                    }
                }

                Section("Credentials") {
                    credentialControls
                }

                if authMethod == .password {
                    Section("Key Setup") {
                        passwordBootstrapControls
                    }
                }

                Section("Metadata") {
                    Toggle("Favorite", isOn: $favorite)
                    TextField("Folder", text: $folder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Tags", text: $tagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(profile == nil ? "New Connection" : "Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cleanupPendingKeyReferences(keeping: originalSSHKeyReference)
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if save() {
                            dismiss()
                        }
                    }
                    .disabled(!isValid)
                }
            }
        }
        .onAppear {
            refreshStoredCredentialState()
        }
        .onChange(of: authMethod) { _, _ in
            refreshStoredCredentialState()
        }
        .onChange(of: host) { _, _ in
            refreshStoredCredentialState()
        }
        .onChange(of: port) { _, _ in
            refreshStoredCredentialState()
        }
        .onChange(of: username) { _, _ in
            refreshStoredCredentialState()
        }
        .onChange(of: keychainManager.credentialRevision) { _, _ in
            refreshStoredCredentialState()
        }
        .fileImporter(
            isPresented: $showingPrivateKeyImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importPrivateKey(from: url)
            case .failure(let error):
                keyError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var credentialControls: some View {
        if authMethod == .password {
            SecureField(
                hasStoredCredential ? "New password (leave empty to keep saved)" : "Password",
                text: $password
            )
            .textContentType(.password)
        } else if keyNeedsPassphraseField {
            SecureField(
                hasStoredCredential ? "New passphrase (leave empty to keep saved)" : "Key passphrase",
                text: $passphrase
            )
            .textContentType(.password)
        } else {
            Label("Generated key is protected by the app vault.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if shouldShowCredentialStorage {
            Toggle("Save in iOS Keychain", isOn: $saveCredential)
        }

        if hasStoredCredential && shouldShowCredentialStorage {
            Label("A \(credentialKind.displayName) is saved for this account.", systemImage: "key.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var privateKeyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let metadata = keyMetadata {
                Label("SSH key ready.", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(metadata.label)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let fingerprint = metadata.fingerprint {
                    Text(fingerprint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Label("No SSH key selected.", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    showingPrivateKeyImporter = true
                } label: {
                    Label(sshKeyReference == nil ? "Import Key" : "Replace Key", systemImage: "tray.and.arrow.down")
                }

                Button {
                    generateKey()
                } label: {
                    Label("Generate Key", systemImage: "key")
                }

                if sshKeyReference != nil {
                    Button("Remove", role: .destructive) {
                        removeSelectedKey()
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let publicKey = visiblePublicKey {
                DisclosureGroup("Public Key") {
                    VStack(alignment: .leading, spacing: 8) {
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

                        HStack {
                            Button {
                                copyPublicKey(publicKey)
                            } label: {
                                Label(
                                    publicKeyCopied ? "Copied" : "Copy",
                                    systemImage: publicKeyCopied ? "checkmark" : "doc.on.doc"
                                )
                            }
                            .tint(publicKeyCopied ? .green : nil)

                            ShareLink(item: publicKey) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            statusMessages
        }
    }

    private var passwordBootstrapControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await generateInstallAndVerifyKey() }
            } label: {
                if keySetupRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Generate & Install Key", systemImage: "key.viewfinder")
                }
            }
            .disabled(!canRunPasswordBootstrap)
            .buttonStyle(.borderedProminent)

            statusMessages
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let keyMessage {
            Label(keyMessage, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        }

        if let keyError {
            Label(keyError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var keyMetadata: MobileSSHKeyMetadata? {
        MobileSSHKeyVault.shared.metadata(for: sshKeyReference)
    }

    private var visiblePublicKey: String? {
        let publicKey = generatedPublicKey.isEmpty ? keyMetadata?.publicKey : generatedPublicKey
        let trimmed = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var keyNeedsPassphraseField: Bool {
        authMethod == .publicKey && sshKeyReference?.isGenerated != true
    }

    private var shouldShowCredentialStorage: Bool {
        authMethod == .password || keyNeedsPassphraseField
    }

    private var isValid: Bool {
        let basicFieldsValid =
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            UInt16(port) != nil

        guard basicFieldsValid else { return false }
        if authMethod == .publicKey {
            return sshKeyReference != nil
        }
        return true
    }

    private var canRunPasswordBootstrap: Bool {
        isServerAddressValid &&
            !keySetupRunning &&
            (!password.isEmpty || hasStoredCredential)
    }

    private var isServerAddressValid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        UInt16(port) != nil
    }

    private var credentialKind: MobileCredentialKind {
        authMethod == .password ? .sshPassword : .sshKeyPassphrase
    }

    private var credentialText: String {
        authMethod == .password ? password : passphrase
    }

    private func makeProfile() -> MobileConnectionProfile {
        MobileConnectionProfile(
            id: profile?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: UInt16(port) ?? 22,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: authMethod,
            kind: kind,
            sshKeyReference: authMethod == .publicKey ? sshKeyReference : nil,
            createdAt: profile?.createdAt ?? Date(),
            lastConnected: profile?.lastConnected,
            favorite: favorite,
            folder: normalizedOptional(folder),
            tags: normalizedTags,
            color: profile?.color,
            notes: normalizedOptional(notes)
        )
    }

    private func bootstrapProfile() -> MobileConnectionProfile {
        MobileConnectionProfile(
            id: profile?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? host.trimmingCharacters(in: .whitespacesAndNewlines)
                : name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: UInt16(port) ?? 22,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: .password,
            kind: kind,
            createdAt: profile?.createdAt ?? Date()
        )
    }

    private var normalizedTags: [String] {
        tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    private func save() -> Bool {
        let updated = makeProfile()
        let credentialAlreadyStored = keychainManager.hasSecret(
            kind: credentialKind,
            account: updated.keychainAccount
        )

        if authMethod == .password {
            if credentialText.isEmpty && !credentialAlreadyStored {
                keychainManager.lastError = "Enter a password before saving this connection."
                return false
            }
            if !credentialText.isEmpty && !saveCredential {
                keychainManager.lastError = "Turn on Save in iOS Keychain to save this password."
                return false
            }
        } else if sshKeyReference == nil {
            keyError = "Generate or import an SSH key before saving this connection."
            return false
        }

        if shouldShowCredentialStorage && saveCredential && !credentialText.isEmpty {
            let savedCredential = keychainManager.saveSecret(
                kind: credentialKind,
                account: updated.keychainAccount,
                secret: credentialText
            )
            guard savedCredential else { return false }
            guard keychainManager.hasSecret(kind: credentialKind, account: updated.keychainAccount) else {
                keychainManager.lastError = "Credential was not available after saving. Build and launch the simulator app with `just run-on-ipad` so iOS Keychain entitlements are present."
                return false
            }
        }

        let staleKind: MobileCredentialKind = authMethod == .password
            ? .sshKeyPassphrase
            : .sshPassword
        keychainManager.deleteSecret(
            kind: staleKind,
            account: updated.keychainAccount,
            reportErrors: false
        )

        onSave(updated)
        cleanupPendingKeyReferences(keeping: updated.sshKeyReference)
        return true
    }

    private func importPrivateKey(from url: URL) {
        do {
            let reference = try MobileSSHKeyVault.shared.importKey(from: url)
            replaceSelectedKey(with: reference, publicKey: MobileSSHKeyVault.shared.metadata(for: reference)?.publicKey)
            authMethod = .publicKey
            keyMessage = "SSH key imported."
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func generateKey() {
        do {
            let generated = try MobileSSHKeyVault.shared.generateEd25519Key(comment: keyComment)
            replaceSelectedKey(with: generated.reference, publicKey: generated.publicKey)
            authMethod = .publicKey
            passphrase = ""
            keyMessage = "SSH key generated."
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    @MainActor
    private func generateInstallAndVerifyKey() async {
        guard !keySetupRunning else { return }

        keySetupRunning = true
        keyMessage = nil
        keyError = nil
        defer {
            keySetupRunning = false
        }

        guard let setupPassword = await resolveBootstrapPassword(), !setupPassword.isEmpty else {
            keyError = MobileSSHKeyBootstrapError.missingPassword.localizedDescription
            return
        }

        do {
            let generated = try MobileSSHKeyVault.shared.generateEd25519Key(comment: keyComment)
            replaceSelectedKey(with: generated.reference, publicKey: generated.publicKey)
            authMethod = .publicKey
            passphrase = ""

            try await MobileSSHKeyBootstrapInstaller.shared.installAndVerify(
                profile: bootstrapProfile(),
                password: setupPassword,
                reference: generated.reference,
                publicKey: generated.publicKey
            )

            password = ""
            saveCredential = false
            keyMessage = "Key installed and verified."
            keyError = nil
            refreshStoredCredentialState()
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func resolveBootstrapPassword() async -> String? {
        if !password.isEmpty {
            return password
        }

        let candidate = bootstrapProfile()
        guard keychainManager.hasSecret(kind: .sshPassword, account: candidate.keychainAccount) else {
            return nil
        }
        return await keychainManager.loadSecret(
            kind: .sshPassword,
            account: candidate.keychainAccount,
            reason: "Unlock the saved password to install the SSH key for \(candidate.name)."
        )
    }

    private func copyPublicKey(_ publicKey: String) {
        UIPasteboard.general.string = publicKey
        publicKeyCopied = true
        keyMessage = "Public key copied."
        keyError = nil

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            publicKeyCopied = false
        }
    }

    private func replaceSelectedKey(with reference: MobileSSHKeyReference, publicKey: String?) {
        if let current = sshKeyReference, pendingKeyReferences.contains(current) {
            MobileSSHKeyVault.shared.deleteKey(for: current)
            pendingKeyReferences.remove(current)
        }

        sshKeyReference = reference
        generatedPublicKey = publicKey ?? ""
        publicKeyCopied = false
        pendingKeyReferences.insert(reference)
    }

    private func removeSelectedKey() {
        if let reference = sshKeyReference, pendingKeyReferences.contains(reference) {
            MobileSSHKeyVault.shared.deleteKey(for: reference)
            pendingKeyReferences.remove(reference)
        }
        sshKeyReference = nil
        generatedPublicKey = ""
        publicKeyCopied = false
        keyMessage = nil
        keyError = nil
    }

    private func cleanupPendingKeyReferences(keeping referenceToKeep: MobileSSHKeyReference?) {
        for reference in pendingKeyReferences where reference != referenceToKeep {
            MobileSSHKeyVault.shared.deleteKey(for: reference)
        }
        pendingKeyReferences.removeAll()
    }

    private func refreshStoredCredentialState() {
        let candidate = makeProfile()
        hasStoredCredential = keychainManager.hasSecret(
            kind: credentialKind,
            account: candidate.keychainAccount
        )
    }

    private var keyComment: String {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = [user, server].filter { !$0.isEmpty }.joined(separator: "@")
        return suffix.isEmpty ? "midnight-ssh-ios" : "midnight-ssh-ios-\(suffix)"
    }
}

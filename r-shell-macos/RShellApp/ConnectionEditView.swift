import SwiftUI
import OSLog
import RShellMacOS

/// Host-key verification dialog. Shown when a server's host key is unknown
/// or has changed.
struct HostKeyAlert: NSViewRepresentable {
    let host: String
    let fingerprint: String
    let isMismatch: Bool
    let onResponse: (HostKeyVerdict) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        // Present once
        guard context.coordinator.presented == false else { return }
        context.coordinator.presented = true
        presentAlert()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator {
        let parent: HostKeyAlert
        var presented = false
        init(_ parent: HostKeyAlert) { self.parent = parent }
    }

    private func presentAlert() {
        let alert = NSAlert()
        if isMismatch {
            alert.messageText = "Host Key Mismatch"
            alert.informativeText = "The host key for \(host) has changed!\n\n" +
                "New fingerprint: \(fingerprint)\n\n" +
                "This could mean someone is intercepting your connection."
            alert.alertStyle = .critical
        } else {
            alert.messageText = "Unknown Host Key"
            alert.informativeText = "The authenticity of host \(host) can't be established.\n\n" +
                "Fingerprint: \(fingerprint)\n\n" +
                "This host key is not known. Proceed with caution."
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "Trust and Continue")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        onResponse(response == .alertFirstButtonReturn ? .trusted : .rejected)
    }
}

enum HostKeyVerdict {
    case trusted
    case rejected
}

// MARK: - Connection edit dialog

struct ConnectionEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var storeManager: ConnectionStoreManager

    let existingProfile: ConnectionProfile?
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var authMethod: AuthMethod = .password
    @State private var password: String = ""
    @State private var privateKeyPath: String = ""
    @State private var passphrase: String = ""
    @State private var folderPath: String = ""
    @State private var favorite: Bool = false
    @State private var tags: String = ""
    @State private var notes: String = ""

    private let logger = Logger(subsystem: "com.r-shell", category: "connection-edit")

    var isEditing: Bool { existingProfile != nil }
    var title: String { isEditing ? "Edit Connection" : "New Connection" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2)
                .padding(.bottom, 4)

            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Name:").frame(width: 80, alignment: .trailing)
                        TextField("My Server", text: $name)
                    }
                    HStack {
                        Text("Host:").frame(width: 80, alignment: .trailing)
                        TextField("example.com", text: $host)
                    }
                    HStack {
                        Text("Port:").frame(width: 80, alignment: .trailing)
                        TextField("22", text: $port)
                            .frame(width: 80)
                        Spacer()
                    }
                    HStack {
                        Text("User:").frame(width: 80, alignment: .trailing)
                        TextField("root", text: $username)
                    }
                }
                .padding(8)
            }

            GroupBox("Authentication") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Method:", selection: $authMethod) {
                        Text("Password").tag(AuthMethod.password)
                        Text("Public Key").tag(AuthMethod.publicKey)
                    }
                    .pickerStyle(.radioGroup)
                    .frame(height: 50)

                    if authMethod == .password {
                        HStack {
                            Text("Password:").frame(width: 80, alignment: .trailing)
                            SecureField("Password", text: $password)
                        }
                    } else {
                        HStack {
                            Text("Key Path:").frame(width: 80, alignment: .trailing)
                            TextField("~/.ssh/id_ed25519", text: $privateKeyPath)
                        }
                        HStack {
                            Text("Passphrase:").frame(width: 80, alignment: .trailing)
                            SecureField("Passphrase", text: $passphrase)
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("Organization") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Folder:").frame(width: 80, alignment: .trailing)
                        TextField("Work/Production", text: $folderPath)
                    }
                    HStack {
                        Toggle("Favorite", isOn: $favorite)
                        Spacer()
                    }
                    HStack {
                        Text("Tags:").frame(width: 80, alignment: .trailing)
                        TextField("comma, separated", text: $tags)
                    }
                }
                .padding(8)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save" : "Add") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || host.isEmpty || username.isEmpty)
            }
        }
        .padding()
        .frame(width: 480)
        .onAppear {
            if let p = existingProfile {
                name = p.name
                host = p.host
                port = String(p.port)
                username = p.username
                authMethod = p.authMethod
                privateKeyPath = p.privateKeyPath ?? ""
                folderPath = p.folderPath ?? ""
                favorite = p.favorite
                tags = p.tags.joined(separator: ", ")
                notes = p.notes ?? ""
            }
        }
    }

    private func save() {
        let p = ConnectionProfile(
            id: existingProfile?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: UInt16(port) ?? 22,
            username: username.trimmingCharacters(in: .whitespaces),
            authMethod: authMethod,
            folderPath: folderPath.trimmingCharacters(in: .whitespaces).isEmpty ? nil : folderPath,
            privateKeyPath: authMethod == .publicKey ? privateKeyPath : nil,
            lastConnected: existingProfile?.lastConnected,
            favorite: favorite,
            tags: tags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            notes: notes
        )

        storeManager.saveOrUpdate(p)

        // Save password/passphrase to Keychain
        if authMethod == .password && !password.isEmpty {
            KeychainManager.shared.savePassword(
                kind: .sshPassword,
                account: p.keychainAccount,
                secret: password
            )
        }
        if authMethod == .publicKey && !passphrase.isEmpty {
            KeychainManager.shared.savePassword(
                kind: .sshKeyPassphrase,
                account: p.keychainAccount,
                secret: passphrase
            )
        }
    }
}

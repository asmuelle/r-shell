import Foundation

@MainActor
final class MobileConnectionStore: ObservableObject {
    @Published private(set) var connections: [MobileConnectionProfile] = []
    @Published var lastError: String?

    private let fileManager = FileManager.default

    private var storeURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("midnight-ssh", isDirectory: true)
            .appendingPathComponent("connections.json")
    }

    func load() {
        let url = storeURL
        guard fileManager.fileExists(atPath: url.path) else {
            connections = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let store = try decoder.decode(MobileConnectionStoreData.self, from: data)
            connections = store.connections
            lastError = nil
        } catch {
            lastError = "Could not load saved connections: \(error.localizedDescription)"
        }
    }

    func upsert(_ profile: MobileConnectionProfile) {
        if let index = connections.firstIndex(where: { $0.id == profile.id }) {
            let previous = connections[index]
            if previous.keychainAccount != profile.keychainAccount {
                MobileKeychainManager.shared.deleteCredentials(for: previous)
            }
            connections[index] = profile
            if previous.sshKeyReference != profile.sshKeyReference {
                deleteUnusedKeyReference(previous.sshKeyReference)
            }
        } else {
            connections.append(profile)
        }
        save()
    }

    func delete(_ profile: MobileConnectionProfile) {
        connections.removeAll { $0.id == profile.id }
        MobileKeychainManager.shared.deleteCredentials(for: profile)
        deleteUnusedKeyReference(profile.sshKeyReference)
        save()
    }

    func markConnected(_ profile: MobileConnectionProfile) {
        var updated = profile
        updated.lastConnected = Date()
        upsert(updated)
    }

    private func save() {
        do {
            let url = storeURL
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(MobileConnectionStoreData(connections: connections))
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
            lastError = nil
        } catch {
            lastError = "Could not save connections: \(error.localizedDescription)"
        }
    }

    private func deleteUnusedKeyReference(_ reference: MobileSSHKeyReference?) {
        guard let reference else { return }
        let stillUsed = connections.contains { $0.sshKeyReference == reference }
        if !stillUsed {
            MobileSSHKeyVault.shared.deleteKey(for: reference)
        }
    }
}

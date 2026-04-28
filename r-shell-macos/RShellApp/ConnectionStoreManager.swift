import Foundation
import OSLog
import RShellMacOS

/// Observable object that owns the connection database, persists it to
/// `Application Support/com.r-shell/connections.json`, and provides CRUD.
@MainActor
class ConnectionStoreManager: ObservableObject {
    static let shared = ConnectionStoreManager()
    private let logger = Logger(subsystem: "com.r-shell", category: "connection-store")

    @Published var connections: [ConnectionProfile] = []
    @Published var folders: [ConnectionFolder] = []

    private static var storeFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.r-shell")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }

    private init() {
        load()
    }

    // MARK: - CRUD

    func saveOrUpdate(_ profile: ConnectionProfile) {
        if let idx = connections.firstIndex(where: { $0.id == profile.id }) {
            connections[idx] = profile
        } else {
            connections.append(profile)
        }
        save()
    }

    func delete(_ profile: ConnectionProfile) {
        connections.removeAll { $0.id == profile.id }
        // Also remove keychain entries
        KeychainManager.shared.deletePassword(kind: .sshPassword, account: profile.keychainAccount)
        KeychainManager.shared.deletePassword(kind: .sshKeyPassphrase, account: profile.keychainAccount)
        save()
    }

    func connection(withId id: String) -> ConnectionProfile? {
        connections.first { $0.id == id }
    }

    func connections(inFolder path: String?) -> [ConnectionProfile] {
        connections.filter { $0.folderPath == path }
    }

    func markConnected(_ profile: ConnectionProfile) {
        var updated = profile
        updated.lastConnected = Date()
        saveOrUpdate(updated)
    }

    // MARK: - Import

    func importFromTauriJSON(url: URL) -> Int {
        do {
            let data = try ImportManager.shared.importFromJSON(url: url)
            var count = 0
            for profile in data.connections where !connections.contains(where: { $0.id == profile.id }) {
                connections.append(profile)
                count += 1
            }
            for folder in data.folders where !folders.contains(where: { $0.id == folder.id }) {
                folders.append(folder)
            }
            save()
            logger.info("Imported \(count) connections from Tauri export")
            return count
        } catch {
            logger.error("Import failed: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(ConnectionStoreData(connections: connections, folders: folders))
            try data.write(to: Self.storeFileURL)
        } catch {
            logger.error("Failed to save connections: \(error.localizedDescription)")
        }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: Self.storeFileURL)
            let store = try JSONDecoder().decode(ConnectionStoreData.self, from: data)
            connections = store.connections
            folders = store.folders
        } catch {
            connections = []
            folders = []
        }
    }
}

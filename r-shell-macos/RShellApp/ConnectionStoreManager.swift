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

    // MARK: - Folder CRUD

    /// Outcome of a folder mutation. The sidebar surfaces failures via
    /// an alert — name collisions are the common one (two siblings
    /// can't share a path) so the user gets an actionable message.
    enum FolderError: LocalizedError {
        case emptyName
        case duplicate(String)
        case notFound

        var errorDescription: String? {
            switch self {
            case .emptyName: return "Folder name can't be empty."
            case .duplicate(let path): return "A folder named \"\(path)\" already exists at this level."
            case .notFound: return "Folder not found."
            }
        }
    }

    /// Immediate children of a folder. `parent == nil` returns
    /// top-level folders. Used by the sidebar's recursive render so
    /// each level only sees its own slice.
    func childFolders(of parent: String?) -> [ConnectionFolder] {
        folders
            .filter { $0.parentPath == parent }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// All distinct folder paths in dotted-list form. Used by the
    /// connection editor's folder picker. `nil` represents root.
    func allFolderPaths() -> [String] {
        folders
            .map(\.path)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Create a new folder. `parent == nil` makes a top-level folder.
    /// Path is computed as `parent/name` (or just `name` at root) and
    /// must not collide with an existing folder at the same level.
    @discardableResult
    func createFolder(
        name: String,
        in parent: String? = nil
    ) throws -> ConnectionFolder {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw FolderError.emptyName }

        let path = composedPath(name: trimmed, parent: parent)
        if folders.contains(where: { $0.path == path }) {
            throw FolderError.duplicate(path)
        }

        let folder = ConnectionFolder(
            name: trimmed,
            path: path,
            parentPath: parent,
            createdAt: Date()
        )
        folders.append(folder)
        save()
        logger.info("Created folder \(path, privacy: .public)")
        return folder
    }

    /// Rename a folder. Rewrites `path` on the folder itself plus
    /// every descendant folder's `path` / `parentPath` and every
    /// profile's `folderPath` so the hierarchy stays internally
    /// consistent. No-ops if the new name matches the current one.
    func renameFolder(id: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw FolderError.emptyName }

        guard let idx = folders.firstIndex(where: { $0.id == id }) else {
            throw FolderError.notFound
        }
        let folder = folders[idx]
        if folder.name == trimmed { return }

        let newPath = composedPath(name: trimmed, parent: folder.parentPath)
        if folders.contains(where: { $0.path == newPath && $0.id != id }) {
            throw FolderError.duplicate(newPath)
        }

        // Rewrite children before mutating the folder itself so
        // `oldPrefix` matches the descendants' current paths.
        rewritePathPrefix(from: folder.path, to: newPath)
        folders[idx].name = trimmed
        folders[idx].path = newPath
        save()
        logger.info("Renamed folder \(folder.path, privacy: .public) → \(newPath, privacy: .public)")
    }

    /// Move a folder to a new parent (or to root with `nil`). Refuses
    /// to move a folder into its own descendant — that would create a
    /// cycle and make the recursive renderer loop forever. Path is
    /// recomputed and all descendants are rewritten in lock-step.
    func moveFolder(id: String, to newParent: String?) throws {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else {
            throw FolderError.notFound
        }
        let folder = folders[idx]
        if folder.parentPath == newParent { return }

        // Cycle guard: refuse if `newParent` is the folder itself or
        // any path nested beneath it. Without this, dragging "Work"
        // into "Work/Production" would corrupt the parent chain.
        if let target = newParent {
            if target == folder.path || target.hasPrefix(folder.path + "/") {
                throw FolderError.duplicate(target)  // reuse the alert path
            }
        }

        let newPath = composedPath(name: folder.name, parent: newParent)
        if folders.contains(where: { $0.path == newPath && $0.id != id }) {
            throw FolderError.duplicate(newPath)
        }

        rewritePathPrefix(from: folder.path, to: newPath)
        folders[idx].parentPath = newParent
        folders[idx].path = newPath
        save()
        logger.info("Moved folder \(folder.path, privacy: .public) → \(newPath, privacy: .public)")
    }

    /// Delete a folder. Children (sub-folders and profiles) move up
    /// to the deleted folder's parent, never to root unless that's
    /// where the deleted folder lived. Picks the gentle option —
    /// users can always re-organise after, but losing connections
    /// on an accidental delete is irreversible.
    func deleteFolder(id: String) throws {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else {
            throw FolderError.notFound
        }
        let folder = folders[idx]

        // Re-parent direct child folders.
        for child in folders where child.parentPath == folder.path {
            try? moveFolder(id: child.id, to: folder.parentPath)
        }
        // Move profiles up.
        for i in connections.indices where connections[i].folderPath == folder.path {
            connections[i].folderPath = folder.parentPath
        }
        folders.removeAll { $0.id == id }
        save()
        logger.info("Deleted folder \(folder.path, privacy: .public); children re-parented")
    }

    /// Move a profile into a folder by path (`nil` = root). The folder
    /// must already exist; create it first via `createFolder` if not.
    func moveProfile(id: String, to folderPath: String?) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        if connections[idx].folderPath == folderPath { return }
        connections[idx].folderPath = folderPath
        save()
    }

    // MARK: - Path helpers

    private func composedPath(name: String, parent: String?) -> String {
        if let parent, !parent.isEmpty {
            return "\(parent)/\(name)"
        }
        return name
    }

    /// Rewrite `path` / `parentPath` on every folder and `folderPath`
    /// on every profile that sits at or below `oldPrefix`. Called from
    /// rename / move so descendants follow the parent atomically.
    private func rewritePathPrefix(from oldPrefix: String, to newPrefix: String) {
        for i in folders.indices {
            let p = folders[i].path
            if p == oldPrefix {
                // The folder itself — caller updates this, skip here.
                continue
            }
            if p.hasPrefix(oldPrefix + "/") {
                let suffix = String(p.dropFirst(oldPrefix.count))
                folders[i].path = newPrefix + suffix
                // parentPath is the path minus the last segment.
                folders[i].parentPath = parentOf(folders[i].path)
            }
        }
        for i in connections.indices {
            guard let fp = connections[i].folderPath else { continue }
            if fp == oldPrefix {
                connections[i].folderPath = newPrefix
            } else if fp.hasPrefix(oldPrefix + "/") {
                let suffix = String(fp.dropFirst(oldPrefix.count))
                connections[i].folderPath = newPrefix + suffix
            }
        }
    }

    private func parentOf(_ path: String) -> String? {
        guard let lastSlash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<lastSlash])
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

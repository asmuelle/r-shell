import Foundation

// MARK: - Auth method

public enum AuthMethod: String, Codable, Sendable, CaseIterable {
    case password
    case publicKey

    public var displayName: String {
        switch self {
        case .password: return "Password"
        case .publicKey: return "Public Key"
        }
    }
}

// MARK: - Connection profile

public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var authMethod: AuthMethod
    public var folderPath: String?

    // Non-credential auth details (key paths are safe to store, passwords go to Keychain)
    public var privateKeyPath: String?

    public var createdAt: Date
    public var lastConnected: Date?
    public var favorite: Bool
    public var tags: [String]
    public var color: String?
    public var notes: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String,
        authMethod: AuthMethod = .password,
        folderPath: String? = nil,
        privateKeyPath: String? = nil,
        createdAt: Date = Date(),
        lastConnected: Date? = nil,
        favorite: Bool = false,
        tags: [String] = [],
        color: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.folderPath = folderPath
        self.privateKeyPath = privateKeyPath
        self.createdAt = createdAt
        self.lastConnected = lastConnected
        self.favorite = favorite
        self.tags = tags
        self.color = color
        self.notes = notes
    }

    /// Keychain account string derived from this profile.
    public var keychainAccount: String { "\(username)@\(host):\(port)" }
}

// MARK: - Connection folder

public struct ConnectionFolder: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var parentPath: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        parentPath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.parentPath = parentPath
        self.createdAt = createdAt
    }
}

// MARK: - Connection store

/// Persisted connection database. Saved as JSON to Application Support.
public struct ConnectionStoreData: Codable, Sendable {
    public var connections: [ConnectionProfile]
    public var folders: [ConnectionFolder]

    public static let empty = ConnectionStoreData(connections: [], folders: [])

    public init(connections: [ConnectionProfile], folders: [ConnectionFolder]) {
        self.connections = connections
        self.folders = folders
    }
}

// MARK: - JSON import format from Tauri app

public struct TauriConnectionImport: Codable, Sendable {
    public var connections: [TauriConnectionEntry]
    public var folders: [TauriFolderEntry]?
}

public struct TauriConnectionEntry: Codable, Sendable {
    public var id: String?
    public var name: String?
    public var host: String?
    public var port: UInt16?
    public var username: String?
    public var authMethod: String?
    public var password: String?
    public var privateKeyPath: String?
    public var passphrase: String?
    public var folder: String?
    public var favorite: Bool?
    public var tags: [String]?
    public var color: String?
    public var description: String?
    public var createdAt: String?
    public var lastConnected: String?
    public var `protocol`: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, password, privateKeyPath
        case passphrase, folder, favorite, tags, color, description, createdAt
        case lastConnected
        case `protocol`
    }
}

public struct TauriFolderEntry: Codable, Sendable {
    public var id: String?
    public var name: String?
    public var path: String?
    public var parentPath: String?
    public var createdAt: String?
}

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

// MARK: - Connection kind

/// What this profile is used for. Both kinds share the underlying
/// SSH transport (russh) — `.sftp` simply skips the PTY-start step
/// and routes the profile straight to the file browser. This matters
/// for accounts where the server allows SFTP but not a login shell
/// (chroot jails, `scponly` users, hosting providers that publish
/// SFTP-only credentials). On those hosts, opening a terminal would
/// fail with a non-zero exec status — declaring the profile as
/// `.sftp` removes that footgun.
public enum ConnectionKind: String, Codable, Sendable, CaseIterable {
    /// Full SSH session: terminal tab + file browser + system monitor.
    case ssh
    /// File transfer only: connects but never starts a PTY. The
    /// sidebar routes the click straight to the Files view.
    case sftp

    public var displayName: String {
        switch self {
        case .ssh: return "SSH (Terminal + Files)"
        case .sftp: return "SFTP only (Files)"
        }
    }

    /// Whether profiles of this kind can host an interactive shell.
    /// Terminal tabs, the live PTY, and the system-monitor view all
    /// gate on this.
    public var supportsTerminal: Bool {
        switch self {
        case .ssh: return true
        case .sftp: return false
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
    public var kind: ConnectionKind
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
        kind: ConnectionKind = .ssh,
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
        self.kind = kind
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

    // Decode with `kind` defaulting to `.ssh` so older saved stores
    // (no `kind` field) round-trip cleanly.
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, kind, folderPath
        case privateKeyPath, createdAt, lastConnected, favorite, tags, color, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decode(UInt16.self, forKey: .port)
        self.username = try c.decode(String.self, forKey: .username)
        self.authMethod = try c.decode(AuthMethod.self, forKey: .authMethod)
        self.kind = try c.decodeIfPresent(ConnectionKind.self, forKey: .kind) ?? .ssh
        self.folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        self.privateKeyPath = try c.decodeIfPresent(String.self, forKey: .privateKeyPath)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        self.favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.color = try c.decodeIfPresent(String.self, forKey: .color)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
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

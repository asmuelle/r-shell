import Foundation

enum MobileAuthMethod: String, Codable, Sendable, CaseIterable {
    case password
    case publicKey

    var displayName: String {
        switch self {
        case .password: return "Password"
        case .publicKey: return "Public Key"
        }
    }
}

enum MobileSSHKeyReference: Codable, Hashable, Sendable {
    case plainPath(String)
    case vaultKey(id: String)
    case generatedVaultKey(id: String)

    var displayName: String {
        switch self {
        case .plainPath(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .vaultKey:
            return "Imported key"
        case .generatedVaultKey:
            return "Generated key"
        }
    }

    var vaultId: String? {
        switch self {
        case .plainPath:
            return nil
        case .vaultKey(let id), .generatedVaultKey(let id):
            return id
        }
    }

    var isGenerated: Bool {
        if case .generatedVaultKey = self { return true }
        return false
    }
}

enum MobileConnectionKind: String, Codable, Sendable, CaseIterable {
    case ssh
    case sftp

    var displayName: String {
        switch self {
        case .ssh: return "SSH (Terminal + Files)"
        case .sftp: return "SFTP only (Files)"
        }
    }

    var supportsTerminal: Bool {
        self == .ssh
    }
}

struct MobileConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var authMethod: MobileAuthMethod
    var kind: MobileConnectionKind
    var sshKeyReference: MobileSSHKeyReference?
    var privateKeyPath: String? {
        get {
            guard case .plainPath(let path) = sshKeyReference else { return nil }
            return path
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            sshKeyReference = trimmed.isEmpty ? nil : .plainPath(trimmed)
        }
    }
    var createdAt: Date
    var lastConnected: Date?
    var favorite: Bool
    var folder: String?
    var tags: [String]
    var color: String?
    var notes: String?

    var keychainAccount: String {
        "\(username)@\(host):\(port)"
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String,
        authMethod: MobileAuthMethod = .password,
        kind: MobileConnectionKind = .ssh,
        privateKeyPath: String? = nil,
        sshKeyReference: MobileSSHKeyReference? = nil,
        createdAt: Date = Date(),
        lastConnected: Date? = nil,
        favorite: Bool = false,
        folder: String? = nil,
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
        if let sshKeyReference {
            self.sshKeyReference = sshKeyReference
        } else if let privateKeyPath,
                  !privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.sshKeyReference = .plainPath(privateKeyPath)
        } else {
            self.sshKeyReference = nil
        }
        self.createdAt = createdAt
        self.lastConnected = lastConnected
        self.favorite = favorite
        self.folder = folder
        self.tags = tags
        self.color = color
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, kind
        case privateKeyPath, sshKeyReference, createdAt, lastConnected, favorite
        case folder, tags, color, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        authMethod = try c.decode(MobileAuthMethod.self, forKey: .authMethod)
        kind = try c.decode(MobileConnectionKind.self, forKey: .kind)

        if let reference = try c.decodeIfPresent(MobileSSHKeyReference.self, forKey: .sshKeyReference) {
            sshKeyReference = reference
        } else if let legacyPath = try c.decodeIfPresent(String.self, forKey: .privateKeyPath),
                  !legacyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sshKeyReference = .plainPath(legacyPath)
        } else {
            sshKeyReference = nil
        }

        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        favorite = try c.decode(Bool.self, forKey: .favorite)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        color = try c.decodeIfPresent(String.self, forKey: .color)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(authMethod, forKey: .authMethod)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(privateKeyPath, forKey: .privateKeyPath)
        try c.encodeIfPresent(sshKeyReference, forKey: .sshKeyReference)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastConnected, forKey: .lastConnected)
        try c.encode(favorite, forKey: .favorite)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(notes, forKey: .notes)
    }
}

struct MobileConnectionStoreData: Codable, Sendable {
    var connections: [MobileConnectionProfile]
}

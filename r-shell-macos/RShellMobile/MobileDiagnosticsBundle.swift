import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum MobileDiagnosticsBundleFactory {
    @MainActor
    static func make(
        bridgeManager: MobileBridgeManager,
        keychainManager: MobileKeychainManager,
        connectionStore: MobileConnectionStore,
        sessionStore: MobileSessionStore,
        terminalPreferences: MobileTerminalPreferences,
        entitlementsStore: MobileEntitlementsStore
    ) -> MobileDiagnosticsBundle {
        let connections = connectionStore.connections
        let sessions = sessionStore.diagnosticsSnapshot(for: connections)

        return MobileDiagnosticsBundle(
            generatedAt: Date(),
            app: .current,
            system: .current,
            bridge: MobileBridgeDiagnostics(
                initialized: bridgeManager.initialized,
                hasInitializationError: bridgeManager.initializationError != nil
            ),
            counts: MobileCountDiagnostics(
                savedConnections: connections.count,
                sshProfiles: connections.filter { $0.kind == .ssh }.count,
                sftpProfiles: connections.filter { $0.kind == .sftp }.count,
                passwordProfiles: connections.filter { $0.authMethod == .password }.count,
                publicKeyProfiles: connections.filter { $0.authMethod == .publicKey }.count,
                favoriteProfiles: connections.filter(\.favorite).count,
                folderedProfiles: connections.filter { $0.folder?.isEmpty == false }.count,
                connectedSessions: sessions.filter { $0.status == "connected" }.count,
                failedSessions: sessions.filter { $0.status == "failed" }.count
            ),
            connections: connections.map {
                MobileSanitizedConnection(
                    profile: $0,
                    keychainManager: keychainManager
                )
            },
            sessions: sessions,
            keychain: MobileKeychainDiagnostics(vaultUnlocked: keychainManager.vaultUnlocked),
            terminal: MobileTerminalDiagnostics(preferences: terminalPreferences),
            store: MobileStoreDiagnostics(entitlementsStore: entitlementsStore)
        )
    }

    static func encode(_ bundle: MobileDiagnosticsBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    static func defaultFilename(generatedAt: Date = Date()) -> String {
        "midnight-ssh-mobile-diagnostics-\(filenameDateFormatter.string(from: generatedAt)).json"
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

struct MobileDiagnosticsBundle: Codable {
    let generatedAt: Date
    let app: MobileAppDiagnostics
    let system: MobileSystemDiagnostics
    let bridge: MobileBridgeDiagnostics
    let counts: MobileCountDiagnostics
    let connections: [MobileSanitizedConnection]
    let sessions: [MobileSessionDiagnostics]
    let keychain: MobileKeychainDiagnostics
    let terminal: MobileTerminalDiagnostics
    let store: MobileStoreDiagnostics
}

struct MobileAppDiagnostics: Codable {
    let bundleIdentifier: String
    let displayName: String
    let version: String
    let build: String

    static var current: MobileAppDiagnostics {
        let info = Bundle.main.infoDictionary ?? [:]
        return MobileAppDiagnostics(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            displayName: (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? "midnight-ssh",
            version: (info["CFBundleShortVersionString"] as? String) ?? "unknown",
            build: (info["CFBundleVersion"] as? String) ?? "unknown"
        )
    }
}

struct MobileSystemDiagnostics: Codable {
    let osVersion: String
    let architecture: String
    let processorCount: Int
    let activeProcessorCount: Int
    let physicalMemoryBytes: UInt64
    let lowPowerModeEnabled: Bool

    static var current: MobileSystemDiagnostics {
        MobileSystemDiagnostics(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: currentArchitecture,
            processorCount: ProcessInfo.processInfo.processorCount,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

struct MobileBridgeDiagnostics: Codable {
    let initialized: Bool
    let hasInitializationError: Bool
}

struct MobileCountDiagnostics: Codable {
    let savedConnections: Int
    let sshProfiles: Int
    let sftpProfiles: Int
    let passwordProfiles: Int
    let publicKeyProfiles: Int
    let favoriteProfiles: Int
    let folderedProfiles: Int
    let connectedSessions: Int
    let failedSessions: Int
}

struct MobileSanitizedConnection: Codable {
    let profileIdHash: String
    let hostHash: String
    let usernameHash: String
    let port: UInt16
    let authMethod: String
    let kind: String
    let hasSSHKeyReference: Bool
    let createdAt: Date
    let lastConnected: Date?
    let favorite: Bool
    let hasFolder: Bool
    let tagCount: Int
    let hasColor: Bool
    let hasNotes: Bool
    let hasStoredCredential: Bool

    @MainActor
    init(profile: MobileConnectionProfile, keychainManager: MobileKeychainManager) {
        profileIdHash = MobileDiagnosticsRedactor.hash(profile.id)
        hostHash = MobileDiagnosticsRedactor.hash(profile.host)
        usernameHash = MobileDiagnosticsRedactor.hash(profile.username)
        port = profile.port
        authMethod = profile.authMethod.rawValue
        kind = profile.kind.rawValue
        hasSSHKeyReference = profile.sshKeyReference != nil
        createdAt = profile.createdAt
        lastConnected = profile.lastConnected
        favorite = profile.favorite
        hasFolder = profile.folder?.isEmpty == false
        tagCount = profile.tags.count
        hasColor = profile.color?.isEmpty == false
        hasNotes = profile.notes?.isEmpty == false
        hasStoredCredential = keychainManager.hasSecret(
            kind: profile.authMethod == .password ? .sshPassword : .sshKeyPassphrase,
            account: profile.keychainAccount
        )
    }
}

struct MobileKeychainDiagnostics: Codable {
    let vaultUnlocked: Bool
}

struct MobileTerminalDiagnostics: Codable {
    let themeId: String
    let fontSize: Double
    let scrollbackLines: Int
    let cursorStyleId: String
    let mouseReporting: Bool
    let optionAsMeta: Bool

    @MainActor
    init(preferences: MobileTerminalPreferences) {
        themeId = preferences.themeId
        fontSize = preferences.clampedFontSize
        scrollbackLines = preferences.clampedScrollbackLines
        cursorStyleId = preferences.cursorStyleId
        mouseReporting = preferences.mouseReporting
        optionAsMeta = preferences.optionAsMeta
    }
}

struct MobileStoreDiagnostics: Codable {
    let proUnlocked: Bool
    let freeSavedHostLimit: Int
    let configuredProductIds: [String]
    let loadedProductCount: Int

    @MainActor
    init(entitlementsStore: MobileEntitlementsStore) {
        proUnlocked = entitlementsStore.isPro
        freeSavedHostLimit = MobileEntitlementsStore.freeSavedHostLimit
        configuredProductIds = entitlementsStore.configuredProductIds
        loadedProductCount = entitlementsStore.products.count
    }
}

struct MobileDiagnosticsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum MobileDiagnosticsRedactor {
    static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }

    static func redactSecrets(_ input: String) -> String {
        let patterns = [
            #"(?i)(password|passphrase|secret|token|authorization)\s*[:=]\s*[^,\s;]+"#,
            #"(?i)(private[_ -]?key)\s*[:=]\s*[^,\s;]+"#,
        ]
        return patterns.reduce(input) { partial, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return partial
            }
            let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
            return regex.stringByReplacingMatches(
                in: partial,
                options: [],
                range: range,
                withTemplate: "$1=[redacted]"
            )
        }
    }
}

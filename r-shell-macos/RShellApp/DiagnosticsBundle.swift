import AppKit
import CryptoKit
import Foundation
import RShellMacOS
import UniformTypeIdentifiers

@MainActor
enum DiagnosticsBundleExporter {
    static func export(
        connectionStore: ConnectionStoreManager,
        tabsStore: TerminalTabsStore,
        layoutManager: LayoutManager
    ) {
        let suggestedName = "midnight-ssh-diagnostics-\(filenameDateFormatter.string(from: Date())).json"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        panel.message = "Export a redacted diagnostics bundle for troubleshooting."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bundle = makeBundle(
                connectionStore: connectionStore,
                tabsStore: tabsStore,
                layoutManager: layoutManager
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(bundle)
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Diagnostics export failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private static func makeBundle(
        connectionStore: ConnectionStoreManager,
        tabsStore: TerminalTabsStore,
        layoutManager: LayoutManager
    ) -> DiagnosticsBundle {
        let connections = connectionStore.connections.map(SanitizedConnection.init(profile:))
        let tabs = tabsStore.tabs.map(SanitizedTab.init(tab:))
        let redactionValues = RedactionValues(
            profiles: connectionStore.connections,
            tabs: tabsStore.tabs
        )

        return DiagnosticsBundle(
            generatedAt: Date(),
            app: AppDiagnostics.current,
            system: SystemDiagnostics.current,
            layout: LayoutDiagnostics(layout: layoutManager.layout),
            counts: CountDiagnostics(
                savedConnections: connectionStore.connections.count,
                folders: connectionStore.folders.count,
                openTabs: tabsStore.tabs.count,
                connectedTabs: tabsStore.tabs.filter { $0.status == .connected }.count
            ),
            connections: connections,
            tabs: tabs,
            keychain: KeychainDiagnostics.current,
            entitlements: EntitlementsDiagnostics.current,
            settings: SettingsDiagnostics.current,
            recentLogs: SettingsDiagnostics.current.includeUnifiedLogsInDiagnostics
                ? redactionValues.redact(runLogShow())
                : "Unified log collection disabled in Privacy settings."
        )
    }

    private static func runLogShow() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--last", "1h",
            "--style", "compact",
            "--predicate", #"subsystem == "com.r-shell""#,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8) ?? ""
            return String(raw.prefix(400_000))
        } catch {
            return "Unable to collect unified logs: \(error.localizedDescription)"
        }
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

private struct DiagnosticsBundle: Codable {
    let generatedAt: Date
    let app: AppDiagnostics
    let system: SystemDiagnostics
    let layout: LayoutDiagnostics
    let counts: CountDiagnostics
    let connections: [SanitizedConnection]
    let tabs: [SanitizedTab]
    let keychain: KeychainDiagnostics
    let entitlements: EntitlementsDiagnostics
    let settings: SettingsDiagnostics
    let recentLogs: String
}

private struct AppDiagnostics: Codable {
    let bundleIdentifier: String
    let displayName: String
    let version: String
    let build: String

    static var current: AppDiagnostics {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppDiagnostics(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            displayName: (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? "midnight-ssh",
            version: (info["CFBundleShortVersionString"] as? String) ?? "unknown",
            build: (info["CFBundleVersion"] as? String) ?? "unknown"
        )
    }
}

private struct SystemDiagnostics: Codable {
    let osVersion: String
    let architecture: String
    let processorCount: Int
    let activeProcessorCount: Int
    let physicalMemoryBytes: UInt64

    static var current: SystemDiagnostics {
        SystemDiagnostics(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: currentArchitecture,
            processorCount: ProcessInfo.processInfo.processorCount,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
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

private struct LayoutDiagnostics: Codable {
    let sidebarVisible: Bool
    let bottomVisible: Bool
    let inspectorVisible: Bool
    let sidebarWidth: Double
    let bottomHeight: Double
    let inspectorWidth: Double

    init(layout: WorkspaceLayout) {
        sidebarVisible = layout.sidebarVisible
        bottomVisible = layout.bottomVisible
        inspectorVisible = layout.inspectorVisible
        sidebarWidth = Double(layout.sidebarWidth)
        bottomHeight = Double(layout.bottomHeight)
        inspectorWidth = Double(layout.inspectorWidth)
    }
}

private struct CountDiagnostics: Codable {
    let savedConnections: Int
    let folders: Int
    let openTabs: Int
    let connectedTabs: Int
}

private struct SanitizedConnection: Codable {
    let profileIdHash: String
    let name: String
    let hostHash: String
    let port: UInt16
    let usernameHash: String
    let authMethod: String
    let kind: String
    let folderHash: String?
    let hasSSHKeyReference: Bool
    let createdAt: Date
    let lastConnected: Date?
    let favorite: Bool
    let tagCount: Int
    let hasNotes: Bool

    init(profile: ConnectionProfile) {
        profileIdHash = Redactor.hash(profile.id)
        name = Redactor.redactFreeText(profile.name)
        hostHash = Redactor.hash(profile.host)
        port = profile.port
        usernameHash = Redactor.hash(profile.username)
        authMethod = profile.authMethod.rawValue
        kind = profile.kind.rawValue
        folderHash = profile.folderPath.map(Redactor.hash)
        hasSSHKeyReference = profile.sshKeyReference != nil
        createdAt = profile.createdAt
        lastConnected = profile.lastConnected
        favorite = profile.favorite
        tagCount = profile.tags.count
        hasNotes = profile.notes?.isEmpty == false
    }
}

private struct SanitizedTab: Codable {
    let tabIdHash: String
    let profileIdHash: String
    let connectionIdHash: String
    let status: String
    let kind: String
    let order: Int
    let hasThemeOverride: Bool
    let ptyGeneration: UInt64

    init(tab: TerminalTab) {
        tabIdHash = Redactor.hash(tab.id.uuidString)
        profileIdHash = Redactor.hash(tab.profile.id)
        connectionIdHash = Redactor.hash(tab.connectionId)
        status = tab.status.rawValue
        kind = tab.effectiveKind.rawValue
        order = tab.order
        hasThemeOverride = tab.themeOverride != nil
        ptyGeneration = tab.ptyGeneration
    }
}

private struct KeychainDiagnostics: Codable {
    let available: Bool
    let accountsByKind: [String: [String]]

    @MainActor
    static var current: KeychainDiagnostics {
        let manager = KeychainManager.shared
        let kinds: [FfiCredentialKind] = [
            .sshPassword,
            .sshKeyPassphrase,
            .sftpPassword,
            .sftpKeyPassphrase,
            .ftpPassword,
        ]
        let accounts = Dictionary(
            uniqueKeysWithValues: kinds.map { kind in
                (
                    kind.rawValue,
                    manager.listAccounts(kind: kind).map(Redactor.hash).sorted()
                )
            }
        )
        return KeychainDiagnostics(
            available: manager.isAvailable,
            accountsByKind: accounts
        )
    }
}

private struct SettingsDiagnostics: Codable {
    let defaultColumns: Int
    let defaultRows: Int
    let fontSize: Double
    let terminalTheme: String
    let scrollbackLines: Int
    let cursorStyle: String
    let mouseReporting: Bool
    let optionAsMeta: Bool
    let copyOnSelect: Bool
    let includeUnifiedLogsInDiagnostics: Bool
    let shareUsageDiagnostics: Bool

    static var current: SettingsDiagnostics {
        let defaults = UserDefaults.standard
        return SettingsDiagnostics(
            defaultColumns: defaults.object(forKey: "defaultColumns") as? Int ?? 80,
            defaultRows: defaults.object(forKey: "defaultRows") as? Int ?? 24,
            fontSize: defaults.object(forKey: "fontSize") as? Double ?? 12,
            terminalTheme: defaults.string(forKey: "terminalTheme") ?? "system",
            scrollbackLines: defaults.object(forKey: "scrollbackLines") as? Int ?? 10_000,
            cursorStyle: defaults.string(forKey: "terminalCursorStyle") ?? "blinkBlock",
            mouseReporting: defaults.object(forKey: "terminalMouseReporting") as? Bool ?? true,
            optionAsMeta: defaults.object(forKey: "terminalOptionAsMeta") as? Bool ?? true,
            copyOnSelect: defaults.object(forKey: "terminalCopyOnSelect") as? Bool ?? false,
            includeUnifiedLogsInDiagnostics: defaults.object(forKey: "privacy.includeUnifiedLogsInDiagnostics") as? Bool ?? true,
            shareUsageDiagnostics: defaults.object(forKey: "privacy.shareUsageDiagnostics") as? Bool ?? false
        )
    }
}

private struct EntitlementsDiagnostics: Codable {
    let tier: String
    let status: String
    let enabledFeatures: [String]
    let savedConnectionLimit: Int?
    let trialEndsAt: Date?
    let licenseKeyHash: String?
    let enforcementEnabled: Bool

    @MainActor
    static var current: EntitlementsDiagnostics {
        let snapshot = EntitlementsStore.shared.snapshot
        return EntitlementsDiagnostics(
            tier: snapshot.tier.rawValue,
            status: snapshot.status.label,
            enabledFeatures: snapshot.enabledFeatures.map(\.rawValue).sorted(),
            savedConnectionLimit: snapshot.savedConnectionLimit,
            trialEndsAt: snapshot.trialEndsAt,
            licenseKeyHash: snapshot.licenseKeyHash,
            enforcementEnabled: Bundle.main.object(forInfoDictionaryKey: "MSSHEnforceEntitlements") as? Bool ?? false
        )
    }
}

private struct RedactionValues {
    let values: [String]

    init(profiles: [ConnectionProfile], tabs: [TerminalTab]) {
        var raw: [String] = []
        for profile in profiles {
            raw.append(contentsOf: [
                profile.id,
                profile.host,
                profile.username,
                profile.keychainAccount,
                profile.sshKeyReference?.displayName ?? "",
            ])
        }
        for tab in tabs {
            raw.append(contentsOf: [
                tab.connectionId,
                tab.profile.host,
                tab.profile.username,
                tab.profile.keychainAccount,
            ])
        }
        values = Array(Set(raw.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
    }

    func redact(_ input: String) -> String {
        var output = Redactor.redactSecrets(input)
        for value in values {
            output = output.replacingOccurrences(of: value, with: "[redacted]")
        }
        return output
    }
}

private enum Redactor {
    static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }

    static func redactFreeText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.count <= 80 ? trimmed : String(trimmed.prefix(77)) + "..."
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

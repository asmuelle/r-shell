import Foundation
import OSLog
import RShellMacOS

/// Owns the set of terminal tabs visible in `MainPanel`. The sidebar
/// drives this when the user picks a profile to connect; `MainPanel`
/// observes it and renders one tab per entry.
///
/// Connect flow (entirely on the main actor — FFI calls hop to the
/// bridge queue internally):
///
///   sidebar.onConnect(profile)
///     → store.openConnection(profile, password)
///         → BridgeManager.connect → SSH handshake
///         → BridgeManager.openTerminal → PTY start, returns generation
///         → append a TerminalTab and select it
///
/// Errors surface as the optional `lastError` string for the UI to
/// display — actual presentation (toast / sheet) is up to the consumer.
@MainActor
final class TerminalTabsStore: ObservableObject {
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var activeTabId: UUID?
    @Published var lastError: String?

    private let logger = Logger(subsystem: "com.r-shell", category: "terminal-tabs")

    /// Open a terminal tab for a saved connection. Resolves the credential
    /// path internally:
    ///
    /// - Password profiles: load from Keychain, prompt if absent, persist
    ///   on first successful entry. On auth-failure with a stored password,
    ///   evict the Keychain entry, prompt, and retry once.
    /// - Public-key profiles: load any saved passphrase from Keychain. On
    ///   connect failure with no passphrase, prompt and retry once.
    ///
    /// `password`/`passphrase` overrides exist for tests and the auto-retry
    /// recursion; passing them short-circuits Keychain lookup, so the retry
    /// path can't recurse forever.
    func openConnection(
        _ profile: ConnectionProfile,
        password: String? = nil,
        passphrase: String? = nil
    ) async {
        logger.info("Opening connection \(profile.name, privacy: .public)")
        lastError = nil

        // Each tab gets its own SSH session — without a session id, opening
        // the same profile twice would replace the first PTY in the Rust
        // connection manager's HashMap. The short prefix is enough for
        // uniqueness and keeps the connection_id readable in logs.
        let sessionId = String(UUID().uuidString.prefix(8))
        let account = profile.keychainAccount

        // Resolve credentials from Keychain or interactive prompt.
        // `usedStoredPassword` distinguishes "loaded from Keychain" from
        // "freshly prompted / caller-provided" so we know whether to evict
        // on auth failure.
        let resolvedPassword: String?
        let resolvedPassphrase: String?
        var usedStoredPassword = false

        switch profile.authMethod {
        case .password:
            if let explicit = password {
                resolvedPassword = explicit
            } else if let stored = KeychainManager.shared.loadPassword(
                kind: .sshPassword,
                account: account
            ) {
                resolvedPassword = stored
                usedStoredPassword = true
            } else {
                resolvedPassword = KeychainManager.shared.promptPassword(
                    account: account,
                    message: "Enter password for \(profile.name) (\(account))"
                )
                if resolvedPassword == nil {
                    logger.info("Password prompt cancelled for \(account, privacy: .public)")
                    return
                }
            }
            resolvedPassphrase = nil

        case .publicKey:
            resolvedPassword = nil
            resolvedPassphrase = passphrase
                ?? KeychainManager.shared.loadPassword(kind: .sshKeyPassphrase, account: account)
        }

        // SSH connect.
        let connectResult = await BridgeManager.shared.connect(
            profile: profile,
            password: resolvedPassword,
            keyPath: profile.privateKeyPath,
            passphrase: resolvedPassphrase,
            sessionId: sessionId
        )

        let connectionId: String
        switch connectResult {
        case .success(let id):
            connectionId = id
            // Persist on first successful interactive entry so the next
            // connect is silent. We only save when the credential we just
            // used wasn't already in Keychain — otherwise we re-save what
            // we read, which is harmless but pointless.
            if profile.authMethod == .password,
               let used = resolvedPassword,
               password == nil,
               !usedStoredPassword {
                KeychainManager.shared.savePassword(
                    kind: .sshPassword,
                    account: account,
                    secret: used
                )
            }

        case .failure(let error):
            let msg = error.localizedDescription

            switch error {
            // Stored password rejected → evict, re-prompt, retry once.
            case .authFailed where profile.authMethod == .password && usedStoredPassword:
                logger.info("Evicting stale Keychain entry for \(account, privacy: .public) and re-prompting")
                KeychainManager.shared.deletePassword(kind: .sshPassword, account: account)
                if let fresh = KeychainManager.shared.promptPassword(
                    account: account,
                    message: "The stored password for \(account) was rejected. Enter a new password."
                ) {
                    await openConnection(profile, password: fresh, passphrase: nil)
                    return
                }

            // Encrypted key, no passphrase available → prompt, retry, persist on success.
            case .passphraseRequired
                where profile.authMethod == .publicKey
                && resolvedPassphrase == nil
                && passphrase == nil:
                if let prompt = KeychainManager.shared.promptPassphrase(
                    keyPath: profile.privateKeyPath ?? account
                ) {
                    logger.info("Retrying connect with prompted passphrase")
                    await openConnection(profile, password: nil, passphrase: prompt)
                    if lastError == nil {
                        KeychainManager.shared.savePassword(
                            kind: .sshKeyPassphrase,
                            account: account,
                            secret: prompt
                        )
                    }
                    return
                }

            default:
                break
            }

            lastError = msg
            logger.error("Connect failed: \(msg, privacy: .public)")
            return
        }

        // PTY start — generation lets us guard against stale closes.
        guard let generation = await BridgeManager.shared.openTerminal(
            connectionId: connectionId
        ) else {
            lastError = "Failed to start terminal session"
            BridgeManager.shared.disconnect(connectionId: connectionId)
            return
        }

        // Append + select. The session is registered when `TerminalView`
        // is materialised (so SwiftTerm's `feed(byteArray:)` is wired
        // before any output arrives).
        let tab = TerminalTab(
            id: UUID(),
            connectionId: connectionId,
            ptyGeneration: generation,
            title: profile.name,
            order: tabs.count
        )
        tabs.append(tab)
        activeTabId = tab.id
    }

    /// Close a tab, tearing down the PTY and disconnecting the SSH session.
    func closeTab(_ tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]

        BridgeManager.shared.closeTerminal(
            connectionId: tab.connectionId,
            generation: tab.ptyGeneration
        )
        BridgeManager.shared.disconnect(connectionId: tab.connectionId)

        tabs.remove(at: index)

        // Promote the next-rightward tab if we just closed the active one.
        if activeTabId == tabId {
            activeTabId = tabs.last?.id
        }
    }

    func setActive(_ tabId: UUID) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        activeTabId = tabId
    }

    var activeTab: TerminalTab? {
        guard let activeTabId else { return nil }
        return tabs.first { $0.id == activeTabId }
    }
}

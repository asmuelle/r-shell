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
    /// Profile ids currently inside an in-flight `openConnection` call.
    /// The sidebar reads this to swap the row's icon for a spinner and
    /// guard the click so a double-tap can't fire a second connect for
    /// the same profile while the first is still in handshake / PTY
    /// start. Pure UI signal — the actual concurrency is driven by the
    /// `await` chain in `openConnection`.
    @Published private(set) var connectingProfileIds: Set<String> = []

    private let logger = Logger(subsystem: "com.r-shell", category: "terminal-tabs")
    private var observers: [NSObjectProtocol] = []

    init() {
        // SwiftTerm fires `setTerminalTitle` (OSC 1/2) on every prompt
        // for shells that propagate it (zsh's prompt does by default,
        // bash with PROMPT_COMMAND likewise). TerminalView posts a
        // notification with the connectionId; we resolve to the
        // matching tab and surface the live title.
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalTitleChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let info = note.userInfo,
                      let connectionId = info["connectionId"] as? String,
                      let title = info["title"] as? String,
                      !title.isEmpty
                else { return }
                self.setTitle(title, forConnectionId: connectionId)
            }
        })

        // Status events from r-shell-core's event bus: connect / disconnect
        // currently fire from the FFI side; future SSH-layer reconnect
        // logic can publish through the same channel.
        observers.append(NotificationCenter.default.addObserver(
            forName: .rshellConnectionStatus,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let info = note.userInfo,
                      let connectionId = info["connectionId"] as? String,
                      let payload = info["payload"] as? String
                else { return }
                self.setStatus(
                    TerminalConnectionStatus.parse(payload: payload),
                    forConnectionId: connectionId
                )
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Update the displayed title for a tab matched by its connection id.
    /// Called from the SwiftTerm `setTerminalTitle` delegate via
    /// NotificationCenter. Falls back silently if no matching tab is
    /// active (the tab may have been closed in flight).
    func setTitle(_ title: String, forConnectionId connectionId: String) {
        guard let idx = tabs.firstIndex(where: { $0.connectionId == connectionId })
        else { return }
        // Don't replace the title with whitespace-only OSC payloads.
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tabs[idx].title = trimmed
    }

    /// Update the connection status for a tab.
    func setStatus(_ status: TerminalConnectionStatus, forConnectionId connectionId: String) {
        guard let idx = tabs.firstIndex(where: { $0.connectionId == connectionId })
        else { return }
        guard tabs[idx].status != status else { return }
        logger.info("\(connectionId, privacy: .public) status: \(status.rawValue)")
        tabs[idx].status = status
    }

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

        // Mark this profile as in-flight only on the outermost call.
        // Auth-retry recursion calls this method again with `password`
        // / `passphrase` arguments — the flag is already set in that
        // case, and removing it from inside the recursion would let
        // the spinner blink off mid-flow. `defer` runs even when the
        // function returns from inside a nested switch, so the flag
        // is always cleared on the way out.
        let isOutermost = !connectingProfileIds.contains(profile.id)
        if isOutermost {
            connectingProfileIds.insert(profile.id)
        }
        defer {
            if isOutermost {
                connectingProfileIds.remove(profile.id)
            }
        }

        // Each tab gets its own SSH session — without a session id, opening
        // the same profile twice would replace the first PTY in the Rust
        // connection manager's HashMap. The short prefix is enough for
        // uniqueness and keeps the connection_id readable in logs.
        let sessionId = String(UUID().uuidString.prefix(8))
        let account = profile.keychainAccount

        // Resolve credentials from Keychain or interactive prompt.
        // `usedStored*` flags distinguish "loaded from Keychain" from
        // "freshly prompted / caller-provided" so we know whether to evict
        // on auth/passphrase failure.
        let resolvedPassword: String?
        let resolvedPassphrase: String?
        var usedStoredPassword = false
        var usedStoredPassphrase = false

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
            if let explicit = passphrase {
                resolvedPassphrase = explicit
            } else if let stored = KeychainManager.shared.loadPassword(
                kind: .sshKeyPassphrase,
                account: account
            ) {
                resolvedPassphrase = stored
                usedStoredPassphrase = true
            } else {
                resolvedPassphrase = nil  // try without; key may be unencrypted
            }
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

            // Host key changed since last connect: prompt the user with
            // both fingerprints, and on confirm forget the stale TOFU
            // entry so the retry trusts the new key. Treats Cancel as
            // a hard stop — surface the message instead of looping.
            case .hostKeyMismatch(let detail):
                let outcome = HostKeyPrompt.presentMismatch(
                    host: profile.host,
                    port: profile.port,
                    detail: detail
                )
                if outcome == .trust {
                    logger.info("User trusted new host key for \(profile.host, privacy: .public):\(profile.port); retrying")
                    await openConnection(profile, password: password, passphrase: passphrase)
                    return
                }

            // Stored passphrase rejected → evict, re-prompt, retry once.
            case .passphraseRequired
                where profile.authMethod == .publicKey && usedStoredPassphrase:
                logger.info("Evicting stale key passphrase for \(account, privacy: .public) and re-prompting")
                KeychainManager.shared.deletePassword(kind: .sshKeyPassphrase, account: account)
                if let fresh = KeychainManager.shared.promptPassphrase(
                    keyPath: profile.privateKeyPath ?? account
                ) {
                    await openConnection(profile, password: nil, passphrase: fresh)
                    if lastError == nil {
                        KeychainManager.shared.savePassword(
                            kind: .sshKeyPassphrase,
                            account: account,
                            secret: fresh
                        )
                    }
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
        // SFTP-only profiles skip this entirely: the file browser uses
        // the SSH transport directly, no shell channel needed.
        let generation: UInt64
        if profile.kind.supportsTerminal {
            guard let g = await BridgeManager.shared.openTerminal(
                connectionId: connectionId
            ) else {
                lastError = "Failed to start terminal session"
                BridgeManager.shared.disconnect(connectionId: connectionId)
                return
            }
            generation = g
        } else {
            generation = 0
        }

        // Append + select. For SSH tabs, the session is registered when
        // `TerminalView` is materialised (so SwiftTerm's
        // `feed(byteArray:)` is wired before any output arrives). SFTP
        // tabs render a placeholder in the terminal pane — the file
        // panel below the split is the actual interaction surface.
        let tab = TerminalTab(
            id: UUID(),
            profile: profile,
            sessionId: sessionId,
            connectionId: connectionId,
            ptyGeneration: generation,
            title: profile.name,
            order: tabs.count
        )
        tabs.append(tab)
        activeTabId = tab.id
    }

    /// Re-establish a dead session in place. Called from the Reconnect
    /// button overlay on disconnected tabs. Reuses the original
    /// connection id (so the SwiftTerm view, registered against this
    /// id, keeps feeding) and the original sessionId (so the
    /// connection_id stays stable in r-shell-core's HashMap).
    func reconnect(tabId: UUID) async {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[idx]
        let profile = tab.profile
        let sessionId = tab.sessionId
        let account = profile.keychainAccount

        logger.info("Reconnecting \(tab.connectionId, privacy: .public)")
        tabs[idx].status = .connecting
        lastError = nil

        // Tear down any leftover Rust state for this id. Idempotent;
        // the connection may already be fully gone (network drop) or
        // half-alive (server killed the channel but TCP is up).
        BridgeManager.shared.disconnect(connectionId: tab.connectionId)

        // Re-resolve credentials. The simple path: load from Keychain
        // for password profiles, no prompt. If the stored credential
        // is rejected this time, the existing auth-fail eviction in
        // openConnection-style flows kicks in next round. For this MVP
        // we don't fall through to interactive prompts on reconnect to
        // keep the fast path silent — user can retry with full
        // credential resolution by re-clicking the sidebar entry.
        let resolvedPassword: String? = profile.authMethod == .password
            ? KeychainManager.shared.loadPassword(kind: .sshPassword, account: account)
            : nil
        let resolvedPassphrase: String? = profile.authMethod == .publicKey
            ? KeychainManager.shared.loadPassword(kind: .sshKeyPassphrase, account: account)
            : nil

        let connectResult = await BridgeManager.shared.connect(
            profile: profile,
            password: resolvedPassword,
            keyPath: profile.privateKeyPath,
            passphrase: resolvedPassphrase,
            sessionId: sessionId
        )

        switch connectResult {
        case .success(let id):
            // Sanity check: r-shell-core should hand back the same
            // connection_id we asked for (same `(user, host, port,
            // sessionId)` tuple). Log + bail if not — we don't want
            // to reroute the live SwiftTerm view to a different
            // connection silently.
            guard id == tab.connectionId else {
                lastError = "Reconnect routed to a different connection id; aborting"
                logger.error("Reconnect mismatch: expected \(tab.connectionId, privacy: .public), got \(id, privacy: .public)")
                tabs[idx].status = .error
                return
            }

            // Bring up a fresh PTY for the same connection_id. SFTP-only
            // tabs skip this — there's no terminal to recreate.
            if profile.kind.supportsTerminal {
                guard let generation = await BridgeManager.shared.openTerminal(
                    connectionId: tab.connectionId
                ) else {
                    lastError = "Failed to start terminal session on reconnect"
                    tabs[idx].status = .error
                    return
                }

                // The SwiftTerm view's session was registered with the OLD
                // generation. Update so the new PTY's output isn't dropped
                // by the stale-frame filter in dispatch.
                tabs[idx].ptyGeneration = generation
                TerminalSessionManager.shared.updateGeneration(generation, forConnectionId: tab.connectionId)
            }
            tabs[idx].status = .connected

        case .failure(let error):
            lastError = error.localizedDescription
            logger.error("Reconnect failed: \(error.localizedDescription, privacy: .public)")
            tabs[idx].status = .error
        }
    }

    /// Close a tab, tearing down the PTY (when present) and disconnecting
    /// the SSH transport.
    func closeTab(_ tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]

        if tab.profile.kind.supportsTerminal {
            BridgeManager.shared.closeTerminal(
                connectionId: tab.connectionId,
                generation: tab.ptyGeneration
            )
        }
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

    /// Set or clear the per-tab theme override. `nil` falls back to the
    /// global `@AppStorage("terminalTheme")`. Triggers SwiftUI to re-run
    /// `TerminalView.updateNSView` for the tab, applying immediately.
    func setTheme(_ themeId: String?, forTabId tabId: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[idx].themeOverride = themeId
    }

    var activeTab: TerminalTab? {
        guard let activeTabId else { return nil }
        return tabs.first { $0.id == activeTabId }
    }
}

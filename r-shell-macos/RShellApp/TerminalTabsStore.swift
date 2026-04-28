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

    /// Open a terminal tab for a saved connection. The password (or key
    /// passphrase) must be supplied by the caller — this store does not
    /// reach into Keychain itself.
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

        // SSH connect.
        let connectResult = await BridgeManager.shared.connect(
            profile: profile,
            password: password,
            keyPath: profile.privateKeyPath,
            passphrase: passphrase,
            sessionId: sessionId
        )

        let connectionId: String
        switch connectResult {
        case .success(let id):
            connectionId = id
        case .failure(let error):
            lastError = error.localizedDescription
            logger.error("Connect failed: \(error.localizedDescription, privacy: .public)")
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

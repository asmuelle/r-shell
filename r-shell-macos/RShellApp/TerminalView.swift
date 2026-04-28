import AppKit
import OSLog
import SwiftTerm
import SwiftUI

// MARK: - SwiftUI wrapper around SwiftTerm.TerminalView

/// `NSViewRepresentable` exposing SwiftTerm's `TerminalView` to SwiftUI,
/// wired to the Rust PTY via `TerminalSessionManager`.
///
/// Data flow on input (typing / paste):
///   SwiftTerm.TerminalView → Coordinator.send(source:data:)
///     → TerminalSessionManager.shared.sendInput
///     → BridgeManager.shared.sendInput
///     → rshellPtyWrite (FFI)
///     → Rust PTY stdin
///
/// Data flow on output:
///   Rust PTY stdout → event-bus payload → RShellEventCallback.onEvent
///     → TerminalSessionManager.dispatch (decodes JSON `Vec<u8>`)
///     → PTYBufferManager.append (adaptive batching)
///     → onFlush callback (registered when the session was created)
///     → DispatchQueue.main.async { term.feed(byteArray: ...) }
///
/// Search bar / theming / per-tab title binding is preserved at the public
/// surface; the SwiftTerm-side implementation defers most of that to
/// Sprint 8.
struct TerminalView: NSViewRepresentable {
    let connectionId: String
    let ptyGeneration: UInt64
    /// Per-tab theme override. When non-nil, takes precedence over the
    /// global `@AppStorage("terminalTheme")`. SwiftUI re-runs
    /// `updateNSView` when this changes, so toggling per-tab via the
    /// tab context menu applies live without rebuilding the view.
    var themeOverride: String?
    /// Whether this tab is the visible / focusable one. When this
    /// transitions to true we make the SwiftTerm view firstResponder so
    /// keyboard input and the standard Find menu (Cmd+F → SwiftTerm's
    /// `performFindPanelAction:`) reach this terminal without requiring
    /// the user to click first.
    var isActive: Bool = true
    @Binding var terminalTitle: String
    @Binding var searchVisible: Bool
    var onSearchQueryChanged: ((String) -> Void)?
    var onSearchNext: (() -> Void)?
    var onSearchPrevious: (() -> Void)?

    /// Live-updated from SettingsView. SwiftUI re-runs `updateNSView` whenever
    /// these change, so editing the Settings tab applies immediately to every
    /// open terminal whose tab doesn't have a `themeOverride`.
    @AppStorage("terminalTheme") private var globalTheme = "system"
    @AppStorage("fontSize") private var fontSize = 12.0

    private var effectiveTheme: String { themeOverride ?? globalTheme }

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let term = SwiftTerm.TerminalView()

        term.terminal?.changeScrollback(10_000)
        term.terminal?.setCursorStyle(.blinkBlock)
        term.allowMouseReporting = true
        term.optionAsMetaKey = true

        applyTheme(to: term)
        applyFont(to: term)

        // The coordinator owns the link to BridgeManager — wire its
        // weak terminalDelegate ref before we register the session, so
        // the very first `feed` doesn't hit a half-built view.
        term.terminalDelegate = context.coordinator
        context.coordinator.term = term

        // Register a session in TerminalSessionManager. Its onFlush is the
        // bridge from PTYBufferManager (background queue) into SwiftTerm
        // (must run on main).
        let connectionId = self.connectionId
        let generation = self.ptyGeneration
        TerminalSessionManager.shared.registerSession(
            connectionId: connectionId,
            generation: generation
        ) { data in
            DispatchQueue.main.async { [weak term] in
                guard let term else { return }
                let bytes = Array(data)
                term.feed(byteArray: bytes[...])
            }
        }

        return term
    }

    func updateNSView(_ term: SwiftTerm.TerminalView, context: Context) {
        // SwiftTerm.TerminalView.setFrameSize handles frame-driven re-grid
        // internally — we don't need to call rshellPtyResize from here.
        //
        // The work this hook DOES need to do is re-apply settings whenever
        // they change in @AppStorage, so theme/font edits propagate to
        // already-open terminals immediately.
        applyTheme(to: term)
        applyFont(to: term)

        // Grab focus on the false → true transition so a freshly-activated
        // tab is keyboard-ready and Cmd+F goes to the right terminal.
        // Calling on every update would fight other firstResponders (e.g.,
        // the inspector text fields) — we only steal focus when the user
        // just switched to this tab.
        if isActive && !context.coordinator.wasActive {
            DispatchQueue.main.async { [weak term] in
                guard let term, let window = term.window else { return }
                window.makeFirstResponder(term)
            }
        }
        context.coordinator.wasActive = isActive
    }

    // MARK: - Theme & font

    private func applyTheme(to term: SwiftTerm.TerminalView) {
        TerminalTheme.resolve(effectiveTheme).apply(to: term)
    }

    private func applyFont(to term: SwiftTerm.TerminalView) {
        let target = NSFont(name: "Menlo", size: CGFloat(fontSize))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        // Skip the assignment when nothing changed — every set triggers
        // SwiftTerm's full re-layout (cell-size recompute, redraw).
        if term.font.pointSize != target.pointSize || term.font.fontName != target.fontName {
            term.font = target
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(connectionId: connectionId)
    }

    static func dismantleNSView(_ nsView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        TerminalSessionManager.shared.unregisterSession(connectionId: coordinator.connectionId)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, TerminalViewDelegate {
        let connectionId: String
        weak var term: SwiftTerm.TerminalView?
        private let logger = Logger(subsystem: "com.r-shell", category: "terminal")

        private var lastCols: Int = 0
        private var lastRows: Int = 0
        private var resizeWorkItem: DispatchWorkItem?

        /// Tracks the previous `isActive` so we only call
        /// `makeFirstResponder` on the inactive→active transition.
        var wasActive: Bool = false

        init(connectionId: String) {
            self.connectionId = connectionId
        }

        // MARK: - Resize debouncing

        func scheduleResize(cols: Int, rows: Int) {
            guard cols != lastCols || rows != lastRows else { return }
            lastCols = cols
            lastRows = rows
            resizeWorkItem?.cancel()

            let connectionId = self.connectionId
            let logger = self.logger
            let item = DispatchWorkItem {
                // Debug-level so this stays out of the default Console
                // unless the user filters for category=terminal. Visible
                // proof that the Coordinator → BridgeManager.resize path
                // fires when the user drags the window or resizes the
                // sidebar. The Rust side then issues SIGWINCH to the
                // remote PTY.
                logger.debug("resize \(connectionId, privacy: .public) → \(cols)x\(rows)")
                BridgeManager.shared.resize(connectionId: connectionId, cols: cols, rows: rows)
            }
            resizeWorkItem = item
            // 100 ms debounce — tmux + interactive resize emit many
            // sizeChanged events in rapid succession.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }

        // MARK: - TerminalViewDelegate

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            // SwiftTerm only invokes `send` for committed text (post-IME).
            // We bypass `TerminalSessionManager.sendInput` (which is
            // `@MainActor`) and call the bridge directly: SwiftTerm's
            // delegate fires off a non-isolated context, and BridgeManager
            // is itself thread-safe via its serial dispatch queue.
            BridgeManager.shared.sendInput(
                connectionId: connectionId,
                data: Data(data)
            )
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            scheduleResize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            NotificationCenter.default.post(
                name: .terminalTitleChanged,
                object: nil,
                userInfo: ["connectionId": connectionId, "title": title]
            )
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
            // OSC 7 (current directory). Useful for tab titles later;
            // ignored for now.
            _ = directory
        }

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {
            // Position 0..1; if we ever build a custom scrollbar we'd use it.
            _ = position
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            // OSC 52 — application requested data on clipboard.
            guard let str = String(data: content, encoding: .utf8) else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(str, forType: .string)
        }

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {
            // Visual updates for accessibility — no-op for now.
            _ = (startY, endY)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let terminalTitleChanged = Notification.Name("terminalTitleChanged")
}

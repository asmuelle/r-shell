import SwiftUI
import AppKit
import OSLog

// MARK: - Stub TerminalView
//
// The full SwiftTerm-backed terminal is Sprint 7 work. The current SwiftTerm
// 1.x API differs from what the previous draft assumed (`TerminalViewDelegate`,
// `TerminalViewScrollPosition`, `nativeCursorColor`, `nativeAnsiColors`,
// `Terminal.scrollback`, `feed(byteArray:)` signature, etc.). Rather than
// half-port the integration, this stub keeps the public surface stable so
// the app compiles and runs, while showing a clear placeholder where the
// terminal will live. PTY plumbing through `TerminalSessionManager` is
// preserved at the call sites — only rendering is stubbed.
//
// To complete Sprint 7:
//   1. Run the SwiftTerm capability audit (project.yml already pulls
//      SwiftTerm via SPM).
//   2. Wrap `SwiftTerm.TerminalView` (NSView subclass) in
//      `NSViewRepresentable`, conforming the Coordinator to whatever the
//      current SwiftTerm public delegate / API is.
//   3. Wire `feed(...)` from the FFI event-bus payload, `send(...)` for
//      keyboard input, and the resize/title delegate callbacks.
//   4. Reconnect theming via the current SwiftTerm color API.

struct TerminalView: View {
    let connectionId: String
    let ptyGeneration: UInt64
    @Binding var terminalTitle: String
    @Binding var searchVisible: Bool
    var onSearchQueryChanged: ((String) -> Void)?
    var onSearchNext: (() -> Void)?
    var onSearchPrevious: (() -> Void)?

    private let logger = Logger(subsystem: "com.r-shell", category: "terminal-stub")

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Terminal pending SwiftTerm integration")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Connection: \(connectionId)  · gen \(ptyGeneration)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .onAppear {
            logger.info("TerminalView stub appeared for \(connectionId, privacy: .public)")
        }
    }
}

// MARK: - Notifications (preserved for downstream observers)

extension Notification.Name {
    static let terminalTitleChanged = Notification.Name("terminalTitleChanged")
}

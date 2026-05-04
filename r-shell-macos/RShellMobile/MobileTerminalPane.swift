import SwiftUI

struct MobileTerminalPane: View {
    @EnvironmentObject private var terminalPreferences: MobileTerminalPreferences

    let connectionId: String
    let profileName: String

    @State private var generation: UInt64?
    @State private var terminalError: String?
    @State private var isStarting = false
    @State private var showingTerminalSettings = false
    @State private var showingCommandPalette = false
    @State private var terminalViewCommand: MobileTerminalViewCommand?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(profileName, systemImage: "terminal")
                    .font(.headline)

                Spacer()

                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    showingCommandPalette = true
                } label: {
                    Image(systemName: "command")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Terminal commands")

                terminalActionsMenu

                Button {
                    showingTerminalSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Terminal settings")
            }

            VStack(spacing: 0) {
                ZStack {
                    if let generation {
                        MobileTerminalView(
                            connectionId: connectionId,
                            ptyGeneration: generation,
                            themeId: terminalPreferences.themeId,
                            fontSize: terminalPreferences.clampedFontSize,
                            scrollbackLines: terminalPreferences.clampedScrollbackLines,
                            cursorStyleId: terminalPreferences.cursorStyleId,
                            mouseReporting: terminalPreferences.mouseReporting,
                            optionAsMeta: terminalPreferences.optionAsMeta,
                            copyOnSelect: terminalPreferences.copyOnSelect,
                            commandRequest: $terminalViewCommand
                        )
                    } else if let terminalError {
                        ContentUnavailableView(
                            "Terminal Unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text(terminalError)
                        )
                    } else {
                        ContentUnavailableView(
                            "Starting Terminal",
                            systemImage: "terminal",
                            description: Text("Opening a PTY on the server.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 420)

                if generation != nil {
                    MobileTerminalAccessoryBar(connectionId: connectionId)
                }
            }
            .background(Color(uiColor: terminalPreferences.theme.background))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .sheet(isPresented: $showingTerminalSettings) {
            MobileTerminalSettingsView()
                .environmentObject(terminalPreferences)
        }
        .sheet(isPresented: $showingCommandPalette) {
            MobileTerminalCommandPaletteView { command in
                performCommand(command)
            }
        }
        .background {
            keyboardShortcuts
        }
        .task {
            await startIfNeeded()
        }
        .onDisappear {
            if let generation {
                MobileTerminalBridge.shared.closeTerminal(
                    connectionId: connectionId,
                    generation: generation
                )
                MobileTerminalSessionManager.shared.unregisterSession(connectionId: connectionId)
                self.generation = nil
            }
        }
    }

    private var terminalActionsMenu: some View {
        Menu {
            ForEach(MobileTerminalCommand.allCases) { command in
                Button {
                    performCommand(command)
                } label: {
                    Label(command.label, systemImage: command.systemImage)
                }
                .disabled(command == .restartPty && generation == nil)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Terminal actions")
    }

    private var keyboardShortcuts: some View {
        ZStack {
            shortcutButton("Focus Terminal", key: "`", modifiers: .command) {
                performCommand(.focus)
            }
            shortcutButton("Terminal Commands", key: "p", modifiers: [.command, .shift]) {
                showingCommandPalette = true
            }
            shortcutButton("Paste", key: "v", modifiers: .command) {
                performCommand(.pasteClipboard)
            }
            shortcutButton("Copy Selection", key: "c", modifiers: .command) {
                performCommand(.copySelection)
            }
            shortcutButton("Select All", key: "a", modifiers: .command) {
                performCommand(.selectAll)
            }
            shortcutButton("Clear Screen", key: "k", modifiers: .command) {
                performCommand(.clearScreen)
            }
            shortcutButton("Interrupt Command", key: ".", modifiers: .command) {
                performCommand(.interrupt)
            }
            shortcutButton("Restart Terminal", key: "r", modifiers: .command) {
                performCommand(.restartPty)
            }
            shortcutButton("Terminal Settings", key: ",", modifiers: .command) {
                performCommand(.settings)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func shortcutButton(
        _ title: String,
        key: KeyEquivalent,
        modifiers: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
    }

    private func performCommand(_ command: MobileTerminalCommand) {
        switch command {
        case .focus:
            issueTerminalViewCommand(.focus)
        case .pasteClipboard:
            issueTerminalViewCommand(.pasteClipboard)
        case .copySelection:
            issueTerminalViewCommand(.copySelection)
        case .selectAll:
            issueTerminalViewCommand(.selectAll)
        case .clearScreen:
            sendInput([0x0C])
            issueTerminalViewCommand(.focus)
        case .interrupt:
            sendInput([0x03])
            issueTerminalViewCommand(.focus)
        case .restartPty:
            Task { await restartTerminal() }
        case .settings:
            showingTerminalSettings = true
        }
    }

    private func issueTerminalViewCommand(_ action: MobileTerminalViewCommand.Action) {
        terminalViewCommand = MobileTerminalViewCommand(action: action)
    }

    private func sendInput(_ bytes: [UInt8]) {
        MobileTerminalBridge.shared.sendInput(connectionId: connectionId, data: Data(bytes))
    }

    private func startIfNeeded() async {
        guard generation == nil, !isStarting else { return }

        isStarting = true
        terminalError = nil
        defer { isStarting = false }

        do {
            generation = try await MobileTerminalBridge.shared.openTerminal(
                connectionId: connectionId,
                cols: 100,
                rows: 30
            )
        } catch {
            terminalError = error.localizedDescription
        }
    }

    private func restartTerminal() async {
        guard !isStarting else { return }

        if let generation {
            MobileTerminalBridge.shared.closeTerminal(
                connectionId: connectionId,
                generation: generation
            )
            MobileTerminalSessionManager.shared.unregisterSession(connectionId: connectionId)
            self.generation = nil
        }

        await startIfNeeded()
    }
}

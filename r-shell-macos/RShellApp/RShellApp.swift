import AppKit
import SwiftUI
import RShellMacOS

@main
struct RShellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var layoutManager = LayoutManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(layoutManager)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    layoutManager.toggleSidebar()
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Toggle Bottom Panel") {
                    layoutManager.toggleBottom()
                }
                .keyboardShortcut("j", modifiers: .command)

                Button("Toggle Inspector") {
                    layoutManager.toggleInspector()
                }
                .keyboardShortcut("m", modifiers: .command)
            }

            CommandMenu("View") {
                Button("Zen Mode") {
                    layoutManager.applyPreset(.zen)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])

                Button("Reset Layout") {
                    layoutManager.applyPreset(.default)
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])

                Divider()

                Button("New Terminal Tab") {
                    let groupId = layoutManager.tabGroups.first?.id ?? UUID()
                    if !layoutManager.tabGroups.contains(where: { $0.id == groupId }) {
                        let group = TabGroup(id: groupId, tabs: [], activeTabId: nil)
                        layoutManager.tabGroups.append(group)
                    }
                    _ = layoutManager.addTab(to: groupId, title: "Terminal")
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") {
                    if let groupId = layoutManager.activeGroupId,
                       let activeTab = layoutManager.tabGroups.first(where: { $0.id == groupId })?.activeTab {
                        layoutManager.closeTab(activeTab.id, in: groupId)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)

                Button("Next Tab") {
                    cycleTab(forward: true)
                }
                .keyboardShortcut(.tab, modifiers: .command)

                Button("Previous Tab") {
                    cycleTab(forward: false)
                }
                .keyboardShortcut(.tab, modifiers: [.command, .shift])
            }

            CommandMenu("Find") {
                Button("Find") {
                    Self.dispatchFind(.showFindPanel)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find Next") {
                    Self.dispatchFind(.next)
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("Find Previous") {
                    Self.dispatchFind(.previous)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button("Use Selection for Find") {
                    Self.dispatchFind(.setFindString)
                }
                .keyboardShortcut("e", modifiers: .command)
            }

            CommandMenu("Help") {
                Button("Check for Updates…") {
                    UpdateManager.shared.checkForUpdates()
                }
            }
        }

        Settings {
            SettingsView()
        }
    }

    /// Send a standard `performFindPanelAction:` to the responder chain so
    /// the focused `SwiftTerm.TerminalView` (which overrides that selector)
    /// gets it. SwiftTerm runs its own find bar + SearchService — we don't
    /// implement the actual search; the menu is the only thing missing in
    /// our shell.
    ///
    /// `performFindPanelAction:` lives on the `NSStandardKeyBindingResponding`
    /// informal protocol, not as a typed `NSResponder` method, so we build
    /// the selector by name rather than via `#selector`.
    private static func dispatchFind(_ action: NSFindPanelAction) {
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        NSApp.sendAction(
            Selector(("performFindPanelAction:")),
            to: nil,
            from: item
        )
    }

    private func cycleTab(forward: Bool) {
        guard let groupId = layoutManager.activeGroupId,
              let group = layoutManager.tabGroups.first(where: { $0.id == groupId }),
              group.tabs.count > 1 else { return }

        let sorted = group.tabs.sorted { $0.order < $1.order }
        let currentIndex = sorted.firstIndex { $0.id == group.activeTabId } ?? 0
        let nextIndex = forward
            ? (currentIndex + 1) % sorted.count
            : (currentIndex - 1 + sorted.count) % sorted.count

        let groupIdx = layoutManager.tabGroups.firstIndex { $0.id == groupId }!
        layoutManager.tabGroups[groupIdx].activeTabId = sorted[nextIndex].id
    }
}

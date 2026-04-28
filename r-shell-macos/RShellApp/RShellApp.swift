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

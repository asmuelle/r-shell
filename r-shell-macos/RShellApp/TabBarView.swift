import SwiftUI
import RShellMacOS

/// Custom tab bar mimicking the VS Code / browser tab style.
struct TabBarView: View {
    let tabs: [WorkspaceTab]
    @Binding var activeTabId: UUID?
    var onClose: (WorkspaceTab) -> Void
    var onNewTab: () -> Void
    /// Tab right-click → "Theme" submenu. `nil` means "use global".
    var onSetTheme: ((WorkspaceTab, String?) -> Void)? = nil
    /// Currently applied per-tab override, by tab id. Used to put a check
    /// mark next to the active selection in the context menu.
    var themeOverrides: [UUID: String] = [:]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isActive: tab.id == activeTabId,
                            currentThemeOverride: themeOverrides[tab.id],
                            onSelect: { activeTabId = tab.id },
                            onClose: { onClose(tab) },
                            onSetTheme: onSetTheme.map { setter in
                                { themeId in setter(tab, themeId) }
                            }
                        )
                    }

                    if tabs.isEmpty {
                        Button(action: onNewTab) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .help("New Connection")
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: LayoutConstants.tabBarHeight)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Single tab item

struct TabItemView: View {
    let tab: WorkspaceTab
    let isActive: Bool
    var currentThemeOverride: String? = nil
    let onSelect: () -> Void
    let onClose: () -> Void
    var onSetTheme: ((String?) -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .font(.system(size: 11))
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .medium))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Close (⌘W)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color(NSColor.selectedContentBackgroundColor).opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .onTapGesture(perform: onSelect)
        .contextMenu {
            if let onSetTheme {
                Menu("Theme") {
                    Button {
                        onSetTheme(nil)
                    } label: {
                        Label(
                            "Use global",
                            systemImage: currentThemeOverride == nil ? "checkmark" : ""
                        )
                    }
                    Divider()
                    ForEach(TerminalTheme.all) { theme in
                        Button {
                            onSetTheme(theme.id)
                        } label: {
                            Label(
                                theme.label,
                                systemImage: currentThemeOverride == theme.id ? "checkmark" : ""
                            )
                        }
                    }
                }
            }
            Button("Close Tab", action: onClose)
        }
    }
}

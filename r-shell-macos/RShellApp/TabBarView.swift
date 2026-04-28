import SwiftUI
import RShellMacOS

/// Custom tab bar mimicking the VS Code / browser tab style.
struct TabBarView: View {
    let tabs: [WorkspaceTab]
    @Binding var activeTabId: UUID?
    var onClose: (WorkspaceTab) -> Void
    var onNewTab: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isActive: tab.id == activeTabId,
                            onSelect: { activeTabId = tab.id },
                            onClose: { onClose(tab) }
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
    let onSelect: () -> Void
    let onClose: () -> Void

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
    }
}

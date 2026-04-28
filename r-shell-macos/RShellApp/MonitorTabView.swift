import SwiftUI

/// Tab view that holds Monitor, Processes, and Logs as sub-tabs.
/// Shown in the main workspace area when the user selects a connection
/// and then picks "Monitor" from the sidebar or context menu.
struct MonitorTabView: View {
    let connectionId: String
    @State private var selectedTab: MonitorTab = .system

    enum MonitorTab: String, CaseIterable {
        case system = "System"
        case processes = "Processes"
        case logs = "Logs"

        var icon: String {
            switch self {
            case .system: return "chart.bar.xaxis"
            case .processes: return "list.bullet"
            case .logs: return "doc.text"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(MonitorTab.allCases, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            switch selectedTab {
            case .system:
                MonitorPanel(connectionId: connectionId)
            case .processes:
                ProcessPanel(connectionId: connectionId)
            case .logs:
                LogPanel(connectionId: connectionId)
            }
        }
    }
}

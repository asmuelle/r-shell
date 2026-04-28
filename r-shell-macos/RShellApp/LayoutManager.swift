import Cocoa
import OSLog
import RShellMacOS

/// Observable object that owns the workspace layout state, persists it
/// to `Application Support/com.r-shell/layout.json`, and responds to
/// keyboard shortcuts.
///
/// Lifecycle: created in `RShellApp` and injected as `@StateObject`.
@MainActor
class LayoutManager: ObservableObject {
    private let logger = Logger(subsystem: "com.r-shell", category: "layout")

    // MARK: - Published panel state

    @Published var layout: WorkspaceLayout {
        didSet { save() }
    }

    // MARK: - Tab state

    @Published var tabGroups: [TabGroup] = []
    @Published var activeGroupId: UUID?

    // MARK: - Persistence URL

    private static var layoutFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.r-shell")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layout.json")
    }

    // MARK: - Init

    init() {
        self.layout = Self.load()
    }

    // MARK: - Panel toggles

    func toggleSidebar() {
        layout.sidebarVisible.toggle()
    }

    func toggleBottom() {
        layout.bottomVisible.toggle()
    }

    func toggleInspector() {
        layout.inspectorVisible.toggle()
    }

    /// Apply a named preset.
    func applyPreset(_ preset: LayoutPreset) {
        switch preset {
        case .default:
            layout = WorkspaceLayout.default
        case .minimal:
            layout = WorkspaceLayout(
                sidebarVisible: false, bottomVisible: false, inspectorVisible: false,
                sidebarWidth: LayoutConstants.defaultSidebarWidth,
                bottomHeight: LayoutConstants.defaultBottomHeight,
                inspectorWidth: LayoutConstants.defaultInspectorWidth
            )
        case .focus:
            layout = WorkspaceLayout(
                sidebarVisible: true, bottomVisible: true, inspectorVisible: false,
                sidebarWidth: LayoutConstants.defaultSidebarWidth,
                bottomHeight: LayoutConstants.defaultBottomHeight,
                inspectorWidth: LayoutConstants.defaultInspectorWidth
            )
        case .fullStack:
            layout = WorkspaceLayout(
                sidebarVisible: true, bottomVisible: true, inspectorVisible: true,
                sidebarWidth: LayoutConstants.defaultSidebarWidth,
                bottomHeight: LayoutConstants.defaultBottomHeight,
                inspectorWidth: LayoutConstants.defaultInspectorWidth
            )
        case .zen:
            layout = WorkspaceLayout(
                sidebarVisible: false, bottomVisible: false, inspectorVisible: false,
                sidebarWidth: 0, bottomHeight: 0, inspectorWidth: 0
            )
        }
    }

    // MARK: - Tab management

    func addTab(to groupId: UUID, title: String) -> WorkspaceTab {
        let groupIndex = tabGroups.firstIndex { $0.id == groupId } ?? 0
        let order = tabGroups[safe: groupIndex]?.tabs.count ?? 0
        let tab = WorkspaceTab(title: title, order: order)
        tabGroups[groupIndex].tabs.append(tab)
        tabGroups[groupIndex].activeTabId = tab.id
        save()
        return tab
    }

    func closeTab(_ tabId: UUID, in groupId: UUID) {
        guard let groupIndex = tabGroups.firstIndex(where: { $0.id == groupId }) else { return }
        tabGroups[groupIndex].tabs.removeAll { $0.id == tabId }
        if tabGroups[groupIndex].activeTabId == tabId {
            tabGroups[groupIndex].activeTabId = tabGroups[groupIndex].tabs.last?.id
        }
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(layout)
            try data.write(to: Self.layoutFileURL)
        } catch {
            logger.error("Failed to save layout: \(error.localizedDescription)")
        }
    }

    private static func load() -> WorkspaceLayout {
        do {
            let data = try Data(contentsOf: layoutFileURL)
            return try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        } catch {
            return .default
        }
    }
}

// MARK: - Layout presets

enum LayoutPreset: String, CaseIterable {
    case `default`
    case minimal
    case focus
    case fullStack
    case zen
}

// `Array.subscript(safe:)` is defined in WorkspaceSplitController.swift.

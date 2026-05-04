import Cocoa
import SwiftUI
import OSLog
import RShellMacOS

/// AppKit split-view controller implementing the three-panel layout.
///
/// Panels (left to right):
///   ┌─────────┬──────────────────┬────────────┐
///   │         │                  │            │
///   │ Sidebar │  Main Workspace  │ Inspector  │
///   │         │  (tabs/splits)   │            │
///   │         │                  │            │
///   └─────────┴──────────────────┴────────────┘
@MainActor
final class WorkspaceSplitController: NSSplitViewController {
    private let logger = Logger(subsystem: "com.r-shell", category: "splitview")
    private let layoutManager: LayoutManager

    // MARK: - Child view controllers

    let sidebarController: NSViewController
    let mainController: NSViewController
    let inspectorController: NSViewController

    // MARK: - Init

    init(layoutManager: LayoutManager) {
        self.layoutManager = layoutManager

        // Build panel view controllers with hosting views
        let storeManager = ConnectionStoreManager.shared

        let sidebar = SidebarPanel(
            storeManager: storeManager,
            selectedConnection: .constant(nil)
        )
        self.sidebarController = NSHostingController(rootView: sidebar)
        self.mainController = NSHostingController(rootView: MainPanel())
        self.inspectorController = NSHostingController(rootView: InspectorPanel())

        super.init(nibName: nil, bundle: nil)

        setupLayout()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Layout setup

    private func setupLayout() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        // --- Outer split: sidebar | main | inspector ---

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = LayoutConstants.minSidebarWidth
        sidebarItem.maximumThickness = LayoutConstants.maxSidebarWidth
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !layoutManager.layout.sidebarVisible
        sidebarItem.holdingPriority = .init(200)
        addSplitViewItem(sidebarItem)

        let mainItem = NSSplitViewItem(viewController: mainController)
        mainItem.canCollapse = false
        addSplitViewItem(mainItem)

        // Inspector (right)
        let inspectorItem = NSSplitViewItem(viewController: inspectorController)
        inspectorItem.minimumThickness = LayoutConstants.minInspectorWidth
        inspectorItem.maximumThickness = LayoutConstants.maxInspectorWidth
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = !layoutManager.layout.inspectorVisible
        inspectorItem.holdingPriority = .init(150)
        addSplitViewItem(inspectorItem)

        // Restore saved sizes
        applyLayout(layoutManager.layout)
    }

    // MARK: - Apply layout state

    func applyLayout(_ layout: WorkspaceLayout) {
        guard isViewLoaded else { return }

        if let sidebarItem = splitViewItems[safe: 0] {
            sidebarItem.isCollapsed = !layout.sidebarVisible
            if layout.sidebarVisible {
                sidebarItem.animator().animations
                splitView.setPosition(layout.sidebarWidth, ofDividerAt: 0)
            }
        }

        let inspectorIndex = splitViewItems.count - 1
        if let inspectorItem = splitViewItems.last {
            inspectorItem.isCollapsed = !layout.inspectorVisible
            if layout.inspectorVisible {
                splitView.setPosition(splitView.bounds.width - layout.inspectorWidth, ofDividerAt: inspectorIndex - 1)
            }
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("Workspace split view loaded")
    }
}

// MARK: - Safe subscript for NSArray

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

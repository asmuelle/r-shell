import Cocoa
import SwiftUI
import OSLog
import RShellMacOS

/// AppKit split-view controller implementing the VS Code-like four-panel layout.
///
/// Panels (left to right, top to bottom):
///   ┌─────────┬──────────────────┬────────────┐
///   │         │                  │            │
///   │ Sidebar │  Main Workspace  │ Inspector  │
///   │         │  (tabs/splits)   │            │
///   │         ├──────────────────┤            │
///   │         │   Bottom Panel   │            │
///   │         │   (logs/output)  │            │
///   └─────────┴──────────────────┴────────────┘
///
/// The vertical divider between sidebar/workspace/inspector is the outer split.
/// The horizontal divider between workspace/bottom is nested inside the center panel.
@MainActor
final class WorkspaceSplitController: NSSplitViewController {
    private let logger = Logger(subsystem: "com.r-shell", category: "splitview")
    private let layoutManager: LayoutManager

    // MARK: - Child view controllers

    let sidebarController: NSViewController
    let mainController: NSViewController
    let bottomController: NSViewController
    let inspectorController: NSViewController

    // MARK: - Nested split (main + bottom)

    private let mainVerticalSplit: NSSplitViewController

    // MARK: - Init

    init(layoutManager: LayoutManager) {
        self.layoutManager = layoutManager
        self.mainVerticalSplit = NSSplitViewController()

        // Build panel view controllers with hosting views
        let storeManager = ConnectionStoreManager.shared

        let sidebar = SidebarPanel(
            storeManager: storeManager,
            selectedConnection: .constant(nil),
            selectedSection: .constant(.terminals)
        )
        self.sidebarController = NSHostingController(rootView: sidebar)
        self.mainController = NSHostingController(rootView: MainPanel())
        self.bottomController = NSHostingController(rootView: BottomPanel())
        self.inspectorController = NSHostingController(rootView: InspectorPanel())

        super.init(nibName: nil, bundle: nil)

        setupLayout()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Layout setup

    private func setupLayout() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        // --- Outer split: sidebar | center column | inspector ---

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = LayoutConstants.minSidebarWidth
        sidebarItem.maximumThickness = LayoutConstants.maxSidebarWidth
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !layoutManager.layout.sidebarVisible
        sidebarItem.holdingPriority = .init(200)
        addSplitViewItem(sidebarItem)

        // Center column = nested vertical split: main workspace | bottom panel
        let mainVerticalItem = NSSplitViewItem(viewController: mainVerticalSplit)
        mainVerticalItem.canCollapse = false
        addSplitViewItem(mainVerticalItem)

        mainVerticalSplit.splitView.isVertical = false
        mainVerticalSplit.splitView.dividerStyle = .thin

        let mainItem = NSSplitViewItem(viewController: mainController)
        mainItem.canCollapse = false
        mainVerticalSplit.addSplitViewItem(mainItem)

        let bottomItem = NSSplitViewItem(viewController: bottomController)
        bottomItem.minimumThickness = LayoutConstants.minBottomHeight
        bottomItem.maximumThickness = LayoutConstants.maxBottomHeight
        bottomItem.canCollapse = true
        bottomItem.isCollapsed = !layoutManager.layout.bottomVisible
        bottomItem.holdingPriority = .init(150)
        mainVerticalSplit.addSplitViewItem(bottomItem)

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

        if let bottomItem = mainVerticalSplit.splitViewItems[safe: 1] {
            bottomItem.isCollapsed = !layout.bottomVisible
            if layout.bottomVisible {
                let dividerIndex = mainVerticalSplit.splitViewItems.count - 1
                let totalHeight = mainVerticalSplit.splitView.bounds.height
                mainVerticalSplit.splitView.setPosition(totalHeight - layout.bottomHeight, ofDividerAt: dividerIndex - 1)
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

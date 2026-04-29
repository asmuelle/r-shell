import AppKit
import SwiftUI

/// SwiftUI wrapper around `NSVisualEffectView` so panels can opt into
/// real macOS materials (sidebar vibrancy, content-background, header, etc.)
/// instead of flat solid fills.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .followsWindowActiveState
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = emphasized
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = emphasized
    }
}

extension View {
    /// Convenience: paint a material behind any view.
    func materialBackground(
        _ material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) -> some View {
        background(VisualEffectView(material: material, blendingMode: blendingMode).ignoresSafeArea())
    }

    /// Sidebar background with the same sidebar material + a subtle
    /// vertical accent-tinted gradient overlay, mirroring the look
    /// modern Finder ships in macOS 14+. Both layers ignore safe
    /// area so they extend under the toolbar / titlebar pill — if
    /// they didn't, you'd see a hairline of the window's solid
    /// background peeking through at the top of the sidebar.
    ///
    /// The gradient is `accent.opacity(0.08)` at the top fading to
    /// fully transparent halfway down. Strong enough to read as
    /// "this surface has personality" without competing with the
    /// list rows for attention. NSVisualEffectView underneath still
    /// supplies the desktop-aware vibrancy that makes the sidebar
    /// feel translucent rather than painted.
    func finderSidebarBackground() -> some View {
        background {
            ZStack {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.08),
                        Color.accentColor.opacity(0.0),
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
            }
            .ignoresSafeArea()
        }
    }
}

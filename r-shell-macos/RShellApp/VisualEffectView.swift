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

    /// Sidebar background with a sidebar material + a strong
    /// vertical accent-tinted gradient that fades top→bottom, the
    /// same look modern Finder leans into when the user has tinted
    /// the desktop. The gradient is intentionally pronounced (top:
    /// 22% accent, bottom: 0%) — at the previous 8% it was lost
    /// entirely under the NSVisualEffectView vibrancy. Both layers
    /// ignore safe area so they extend under the toolbar; otherwise
    /// the window's solid background bleeds through at the top.
    ///
    /// `.blendMode(.plusLighter)` mixes the gradient *with* the
    /// vibrant material instead of compositing on top, so the
    /// accent reads through the desktop-aware blur instead of
    /// covering it.
    func finderSidebarBackground() -> some View {
        background {
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.22),
                            Color.accentColor.opacity(0.04),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.plusLighter)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
        }
    }
}

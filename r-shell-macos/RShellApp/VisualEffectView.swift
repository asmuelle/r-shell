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
}

import Foundation

// MARK: - Feature flags

/// Central registry of feature flags that gate incomplete v1 features.
///
/// Before the beta, set any feature that isn't stable to `false`.
/// This hides UI elements (menu items, toolbar buttons, sidebar entries)
/// without removing the code paths.
public enum FeatureFlags: String, CaseIterable, Sendable {
    /// RDP/VNC remote desktop — stubs only, not v1-ready
    case remoteDesktop = "Remote Desktop"
    /// SFTP standalone connection (separate from SSH file browser)
    case standaloneSFTP = "Standalone SFTP"
    /// FTP/FTPS connections
    case ftp = "FTP/FTPS"
    /// Drag-and-drop file transfers between local and remote panes
    case dragDrop = "Drag & Drop Transfer"
    /// Image/sixel protocol in terminal
    case terminalImages = "Terminal Image Support"
    /// GPU monitoring tab
    case gpuMonitor = "GPU Monitor"

    /// Whether this feature is enabled for the current build.
    ///
    /// In Debug builds, all features are visible. In Release (beta) builds,
    /// only the stable subset is enabled.
    public var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        switch self {
        case .remoteDesktop: return false
        case .standaloneSFTP: return false
        case .ftp: return false
        case .dragDrop: return false
        case .terminalImages: return false
        case .gpuMonitor: return false
        }
        #endif
    }
}

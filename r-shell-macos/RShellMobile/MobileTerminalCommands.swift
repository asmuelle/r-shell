import Foundation

struct MobileTerminalViewCommand: Equatable {
    let id = UUID()
    let action: Action

    enum Action: Equatable {
        case focus
        case copySelection
        case pasteClipboard
        case selectAll
    }
}

enum MobileTerminalCommand: CaseIterable, Identifiable {
    case focus
    case pasteClipboard
    case copySelection
    case selectAll
    case clearScreen
    case interrupt
    case restartPty
    case settings

    var id: Self { self }

    var label: String {
        switch self {
        case .focus:
            return "Focus Terminal"
        case .pasteClipboard:
            return "Paste"
        case .copySelection:
            return "Copy Selection"
        case .selectAll:
            return "Select All"
        case .clearScreen:
            return "Clear Screen"
        case .interrupt:
            return "Interrupt Command"
        case .restartPty:
            return "Restart Terminal"
        case .settings:
            return "Terminal Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .focus:
            return "cursorarrow.rays"
        case .pasteClipboard:
            return "doc.on.clipboard"
        case .copySelection:
            return "doc.on.doc"
        case .selectAll:
            return "selection.pin.in.out"
        case .clearScreen:
            return "rectangle.dashed"
        case .interrupt:
            return "stop.circle"
        case .restartPty:
            return "arrow.clockwise"
        case .settings:
            return "slider.horizontal.3"
        }
    }
}

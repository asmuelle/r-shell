import SwiftTerm
import SwiftUI
import UIKit

struct MobileTerminalView: UIViewRepresentable {
    let connectionId: String
    let ptyGeneration: UInt64
    let themeId: String
    let fontSize: Double
    let scrollbackLines: Int
    let cursorStyleId: String
    let mouseReporting: Bool
    let optionAsMeta: Bool
    let copyOnSelect: Bool
    @Binding var commandRequest: MobileTerminalViewCommand?

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let term = SwiftTerm.TerminalView(frame: .zero)
        applyAppearance(to: term)

        term.terminalDelegate = context.coordinator
        context.coordinator.term = term

        term.addPointerInteraction()

        MobileTerminalSessionManager.shared.registerSession(
            connectionId: connectionId,
            generation: ptyGeneration
        ) { data in
            DispatchQueue.main.async { [weak term] in
                guard let term else { return }
                let bytes = Array(data)
                term.feed(byteArray: bytes[...])
            }
        }

        DispatchQueue.main.async { [weak term] in
            _ = term?.becomeFirstResponder()
        }

        return term
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        applyAppearance(to: uiView)
        context.coordinator.handle(commandRequest, in: uiView)
        DispatchQueue.main.async { [weak uiView] in
            _ = uiView?.becomeFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        MobileTerminalSessionManager.shared.unregisterSession(connectionId: coordinator.connectionId)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(connectionId: connectionId)
    }

    private func applyAppearance(to term: SwiftTerm.TerminalView) {
        let targetFont = UIFont.monospacedSystemFont(
            ofSize: CGFloat(min(22, max(10, fontSize))),
            weight: .regular
        )

        MobileTerminalTheme.resolve(themeId).apply(to: term)
        if term.font.pointSize != targetFont.pointSize || term.font.fontName != targetFont.fontName {
            term.font = targetFont
        }
        term.getTerminal().changeScrollback(min(100_000, max(500, scrollbackLines)))
        term.getTerminal().setCursorStyle(CursorStyle.from(string: cursorStyleId) ?? .blinkBlock)
        term.allowMouseReporting = mouseReporting
        term.optionAsMetaKey = optionAsMeta
        term.keyboardDismissMode = .interactive
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let connectionId: String
        weak var term: SwiftTerm.TerminalView?

        private var lastCols = 0
        private var lastRows = 0
        private var resizeWorkItem: DispatchWorkItem?
        private var lastHandledCommandId: UUID?

        init(connectionId: String) {
            self.connectionId = connectionId
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            MobileTerminalBridge.shared.sendInput(connectionId: connectionId, data: Data(data))
        }

        func handle(_ command: MobileTerminalViewCommand?, in terminalView: SwiftTerm.TerminalView) {
            guard let command, command.id != lastHandledCommandId else { return }
            lastHandledCommandId = command.id

            switch command.action {
            case .focus:
                _ = terminalView.becomeFirstResponder()
            case .copySelection:
                terminalView.copy(nil)
            case .pasteClipboard:
                terminalView.paste(nil)
            case .selectAll:
                terminalView.selectAll(nil)
            }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            guard newCols != lastCols || newRows != lastRows else { return }
            lastCols = newCols
            lastRows = newRows
            resizeWorkItem?.cancel()

            let connectionId = self.connectionId
            let item = DispatchWorkItem {
                MobileTerminalBridge.shared.resize(
                    connectionId: connectionId,
                    cols: newCols,
                    rows: newRows
                )
            }
            resizeWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            _ = title
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
            _ = directory
        }

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {
            _ = position
        }

        func requestOpenLink(
            source: SwiftTerm.TerminalView,
            link: String,
            params: [String: String]
        ) {
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }

        func bell(source: SwiftTerm.TerminalView) {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            guard let string = String(data: content, encoding: .utf8) else { return }
            UIPasteboard.general.string = string
        }

        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {
            _ = content
        }

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {
            _ = (startY, endY)
        }
    }
}

extension SwiftTerm.TerminalView {
    func addPointerInteraction() {
        let interaction = UIPointerInteraction(delegate: nil)
        addInteraction(interaction)
    }
}

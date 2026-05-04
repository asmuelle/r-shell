import AppKit
import SwiftUI

/// Minimal text editor for remote files. Fetches content on open and
/// provides a Save button that writes back via the FFI layer.
struct FileEditView: View {
    @Environment(\.dismiss) private var dismiss
    let connectionId: String
    let path: String
    @State var content: String
    var canRunRemoteCommands: Bool = true
    var onSave: (String) async throws -> Void

    @State private var originalContent = ""
    @State private var isModified = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showingDiffReview = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                if isModified {
                    Text("Modified")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                }

                Button("Review & Save") {
                    showingDiffReview = true
                }
                .disabled(!isModified || isSaving)
                .keyboardShortcut("s", modifiers: .command)

                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            editorStatusBar

            Divider()

            if let saveError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                Divider()
            }

            SyntaxTextEditor(
                text: $content,
                syntax: FileSyntax(path: path),
                isEditable: !isSaving
            )
                .onChange(of: content) { _ in
                    isModified = content != originalContent
                    saveError = nil
                }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 420)
        .sheet(isPresented: $showingDiffReview) {
            FileDiffReviewSheet(
                path: path,
                original: originalContent,
                revised: content,
                isSaving: isSaving,
                onCancel: {
                    showingDiffReview = false
                },
                onConfirm: {
                    save()
                }
            )
        }
        .onAppear {
            originalContent = content
        }
    }

    private func save() {
        saveError = nil
        isSaving = true
        Task { @MainActor in
            do {
                let backup = canRunRemoteCommands
                    ? try await MacSafeConfigSave.prepareIfNeeded(
                        connectionId: connectionId,
                        remotePath: path
                    )
                    : nil
                try await onSave(content)
                if let backup {
                    _ = try await MacSafeConfigSave.validate(
                        connectionId: connectionId,
                        backup: backup
                    )
                }
                ActivityLogStore.shared.record(
                    title: "File saved",
                    detail: path,
                    connectionId: connectionId,
                    icon: "doc.text",
                    severity: .success
                )
                originalContent = content
                isModified = false
                isSaving = false
                showingDiffReview = false
                dismiss()
            } catch {
                ActivityLogStore.shared.record(
                    title: "File save failed",
                    detail: path,
                    connectionId: connectionId,
                    icon: "exclamationmark.triangle.fill",
                    severity: .critical
                )
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }

    private var editorStatusBar: some View {
        HStack(spacing: 12) {
            Label(FileSyntax(path: path).displayName, systemImage: "curlybraces")
            Label("\(lineCount) lines", systemImage: "number")
            if isModified {
                Label("\(changedLineCount) changed", systemImage: "plus.forwardslash.minus")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Label(safetySummary, systemImage: "checkmark.shield")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var lineCount: Int {
        max(1, content.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    private var changedLineCount: Int {
        let original = originalContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let revised = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let maxCount = max(original.count, revised.count)
        guard maxCount > 0 else { return 0 }
        return (0..<maxCount).reduce(into: 0) { count, index in
            let lhs = index < original.count ? original[index] : nil
            let rhs = index < revised.count ? revised[index] : nil
            if lhs != rhs {
                count += 1
            }
        }
    }

    private var safetySummary: String {
        if MacSafeConfigSave.shouldBackup(path) {
            guard canRunRemoteCommands else { return "Diff review before SFTP save" }
            return "Backup before save; validation when available"
        }
        return "Diff review before save"
    }
}

private enum FileSyntax: Equatable {
    case plain
    case shell
    case sql
    case systemdUnit
    case yaml

    init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "sh":
            self = .shell
        case "sql":
            self = .sql
        case "service":
            self = .systemdUnit
        case "yaml", "yml":
            self = .yaml
        default:
            self = .plain
        }
    }

    var displayName: String {
        switch self {
        case .plain: return "Plain text"
        case .shell: return "Shell"
        case .sql: return "SQL"
        case .systemdUnit: return "systemd unit"
        case .yaml: return "YAML"
        }
    }
}

private struct SyntaxTextEditor: NSViewRepresentable {
    @Binding var text: String
    let syntax: FileSyntax
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, syntax: syntax)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.string = text
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.font = SyntaxHighlighter.font
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.autoresizingMask = [.width, .height]
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        context.coordinator.applyHighlighting(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.syntax = syntax

        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        textView.backgroundColor = NSColor.textBackgroundColor

        if textView.string != text {
            context.coordinator.isProgrammaticChange = true
            textView.string = text
            context.coordinator.isProgrammaticChange = false
        }
        context.coordinator.applyHighlighting(to: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var syntax: FileSyntax
        var isProgrammaticChange = false
        private var isApplyingHighlighting = false

        init(text: Binding<String>, syntax: FileSyntax) {
            self.text = text
            self.syntax = syntax
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticChange,
                  let textView = notification.object as? NSTextView
            else { return }

            text.wrappedValue = textView.string
            applyHighlighting(to: textView)
        }

        func applyHighlighting(to textView: NSTextView) {
            guard !isApplyingHighlighting, let storage = textView.textStorage else { return }
            isApplyingHighlighting = true
            let selectedRanges = textView.selectedRanges

            storage.beginEditing()
            SyntaxHighlighter.apply(to: storage, syntax: syntax)
            storage.endEditing()

            textView.selectedRanges = selectedRanges
            textView.typingAttributes = SyntaxHighlighter.baseAttributes
            isApplyingHighlighting = false
        }
    }
}

private enum SyntaxHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
    }

    private static var commentAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
    }

    private static var shellKeywordAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.systemBlue]
    }

    private static var shellVariableAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.systemPurple]
    }

    private static var sqlKeywordAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.systemBlue]
    }

    private static var sqlNumberAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.systemOrange]
    }

    private static var stringAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.systemGreen]
    }

    private static var yamlKeyAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.systemBlue]
    }

    private static var yamlScalarAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.systemOrange]
    }

    private static var systemdSectionAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.systemPurple
        ]
    }

    private static var systemdKeyAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.systemBlue]
    }

    private static var systemdValueAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.systemOrange]
    }

    static func apply(to storage: NSTextStorage, syntax: FileSyntax) {
        let nsString = storage.string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        guard fullRange.length > 0 else { return }

        storage.setAttributes(baseAttributes, range: fullRange)

        switch syntax {
        case .plain:
            return
        case .shell:
            highlightShell(storage, range: fullRange)
        case .sql:
            highlightSQL(storage, range: fullRange)
        case .systemdUnit:
            highlightSystemdUnit(storage, range: fullRange)
        case .yaml:
            highlightYAML(storage, range: fullRange)
        }
    }

    private static func highlightShell(_ storage: NSTextStorage, range: NSRange) {
        applyRegex(
            #"(?<![A-Za-z0-9_])(?:if|then|else|elif|fi|for|while|until|do|done|case|esac|function|in|select|time|coproc|return|exit|export|local|readonly|declare|typeset|source|alias|unalias|trap|shift|test)(?![A-Za-z0-9_])"#,
            to: storage,
            range: range,
            attributes: shellKeywordAttributes
        )
        applyRegex(
            #"\$\{[^}\n]+\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9#?*!@$-]"#,
            to: storage,
            range: range,
            attributes: shellVariableAttributes
        )
        applyRegex(
            #""(?:\\.|[^"\\])*"|'[^'\n]*'"#,
            to: storage,
            range: range,
            attributes: stringAttributes
        )
        applyCommentHighlighting(to: storage)
    }

    private static func highlightSQL(_ storage: NSTextStorage, range: NSRange) {
        applyRegex(
            #"(?<![A-Za-z0-9_])(?:add|all|alter|and|as|asc|begin|between|by|cascade|case|check|commit|constraint|create|cross|database|default|delete|desc|distinct|drop|else|end|exists|foreign|from|full|grant|group|having|if|in|index|inner|insert|into|is|join|key|left|like|limit|not|null|offset|on|or|order|outer|primary|procedure|references|returning|revoke|right|rollback|schema|select|sequence|set|table|then|trigger|truncate|union|unique|update|using|values|view|when|where|with)(?![A-Za-z0-9_])"#,
            to: storage,
            range: range,
            options: [.caseInsensitive],
            attributes: sqlKeywordAttributes
        )
        applyRegex(
            #"(?<![A-Za-z0-9_])-?\d+(?:\.\d+)?(?![A-Za-z0-9_])"#,
            to: storage,
            range: range,
            attributes: sqlNumberAttributes
        )
        applyRegex(
            #"'(?:''|[^'])*'"#,
            to: storage,
            range: range,
            attributes: stringAttributes
        )
        applyRegex(
            #"(?m)--.*$"#,
            to: storage,
            range: range,
            attributes: commentAttributes
        )
        applyRegex(
            #"/\*.*?\*/"#,
            to: storage,
            range: range,
            options: [.dotMatchesLineSeparators],
            attributes: commentAttributes
        )
    }

    private static func highlightSystemdUnit(_ storage: NSTextStorage, range: NSRange) {
        applyRegex(
            #"(?m)^\s*(\[[A-Za-z][A-Za-z0-9_.-]*\])"#,
            to: storage,
            range: range,
            captureGroup: 1,
            attributes: systemdSectionAttributes
        )
        applyRegex(
            #"(?m)^\s*([A-Za-z][A-Za-z0-9_.-]*)(?=\s*=)"#,
            to: storage,
            range: range,
            captureGroup: 1,
            attributes: systemdKeyAttributes
        )
        applyRegex(
            #"(?<=\=)(?:true|false|yes|no|on|off|null|none|-?\d+(?:\.\d+)?[A-Za-z]*)\b"#,
            to: storage,
            range: range,
            options: [.caseInsensitive],
            attributes: systemdValueAttributes
        )
        applyRegex(
            #""(?:\\.|[^"\\])*"|'[^'\n]*'"#,
            to: storage,
            range: range,
            attributes: stringAttributes
        )
        applySystemdCommentHighlighting(to: storage)
    }

    private static func highlightYAML(_ storage: NSTextStorage, range: NSRange) {
        applyRegex(
            #"(?m)^([ \t-]*)([A-Za-z0-9_.-]+)([ \t]*:)"#,
            to: storage,
            range: range,
            captureGroup: 2,
            attributes: yamlKeyAttributes
        )
        applyRegex(
            #"(?<![A-Za-z0-9_])[&*][A-Za-z0-9_-]+"#,
            to: storage,
            range: range,
            attributes: shellVariableAttributes
        )
        applyRegex(
            #"(?<=[:\[, \t-])(?:true|false|null|~|-?\d+(?:\.\d+)?)(?=$|[,\] \t#])"#,
            to: storage,
            range: range,
            options: [.caseInsensitive],
            attributes: yamlScalarAttributes
        )
        applyRegex(
            #""(?:\\.|[^"\\])*"|'[^'\n]*'"#,
            to: storage,
            range: range,
            attributes: stringAttributes
        )
        applyCommentHighlighting(to: storage)
    }

    private static func applyRegex(
        _ pattern: String,
        to storage: NSTextStorage,
        range: NSRange,
        options: NSRegularExpression.Options = [],
        captureGroup: Int = 0,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options)
        else { return }

        regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match else { return }
            let highlightedRange = captureGroup > 0 ? match.range(at: captureGroup) : match.range
            guard highlightedRange.location != NSNotFound, highlightedRange.length > 0 else { return }
            storage.addAttributes(attributes, range: highlightedRange)
        }
    }

    private static func applyCommentHighlighting(to storage: NSTextStorage) {
        let nsString = storage.string as NSString
        var location = 0

        while location < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
            let line = nsString.substring(with: lineRange)
            if let offset = commentOffset(in: line) {
                storage.addAttributes(
                    commentAttributes,
                    range: NSRange(
                        location: lineRange.location + offset,
                        length: lineRange.length - offset
                    )
                )
            }

            let nextLocation = NSMaxRange(lineRange)
            if nextLocation <= location { break }
            location = nextLocation
        }
    }

    private static func commentOffset(in line: String) -> Int? {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false
        var previous: Character?
        var utf16Offset = 0

        for character in line {
            defer {
                previous = character
                utf16Offset += character.utf16.count
            }

            if escaped {
                escaped = false
                continue
            }

            if character == "\\" && !inSingleQuote {
                escaped = true
                continue
            }

            if character == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }

            if character == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }

            if character == "#",
               !inSingleQuote,
               !inDoubleQuote,
               isWhitespace(previous) {
                return utf16Offset
            }
        }

        return nil
    }

    private static func applySystemdCommentHighlighting(to storage: NSTextStorage) {
        let nsString = storage.string as NSString
        var location = 0

        while location < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
            let line = nsString.substring(with: lineRange)
            if let offset = systemdCommentOffset(in: line) {
                storage.addAttributes(
                    commentAttributes,
                    range: NSRange(
                        location: lineRange.location + offset,
                        length: lineRange.length - offset
                    )
                )
            }

            let nextLocation = NSMaxRange(lineRange)
            if nextLocation <= location { break }
            location = nextLocation
        }
    }

    private static func systemdCommentOffset(in line: String) -> Int? {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false
        var previous: Character?
        var utf16Offset = 0

        for character in line {
            defer {
                previous = character
                utf16Offset += character.utf16.count
            }

            if escaped {
                escaped = false
                continue
            }

            if character == "\\" {
                escaped = true
                continue
            }

            if character == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }

            if character == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }

            if (character == "#" || character == ";"),
               !inSingleQuote,
               !inDoubleQuote,
               isWhitespace(previous) {
                return utf16Offset
            }
        }

        return nil
    }

    private static func isWhitespace(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}

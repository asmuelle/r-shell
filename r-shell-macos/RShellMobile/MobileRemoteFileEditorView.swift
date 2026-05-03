import SwiftUI
import UIKit

struct MobileRemoteFileDocument: Identifiable {
    let id = UUID()
    let connectionId: String
    let remotePath: String
    let fileName: String
    let initialContent: String

    var syntax: MobileFileSyntax {
        MobileFileSyntax(fileName: fileName)
    }
}

struct MobileRemoteFileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let document: MobileRemoteFileDocument
    let onSave: (String) async throws -> Void
    let onSaved: () -> Void

    @State private var content: String
    @State private var originalContent: String
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var safetyMessage: String?
    @State private var showingDiffReview = false

    init(
        document: MobileRemoteFileDocument,
        onSave: @escaping (String) async throws -> Void,
        onSaved: @escaping () -> Void
    ) {
        self.document = document
        self.onSave = onSave
        self.onSaved = onSaved
        _content = State(initialValue: document.initialContent)
        _originalContent = State(initialValue: document.initialContent)
    }

    private var isModified: Bool {
        content != originalContent
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(document.remotePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if isModified {
                        Text("Modified")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemGroupedBackground))

                editorStatusBar

                Divider()

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                    Divider()
                }

                if let safetyMessage {
                    Label(safetyMessage, systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                    Divider()
                }

                MobileSyntaxTextView(
                    text: $content,
                    syntax: document.syntax,
                    isEditable: !isSaving
                )
            }
            .navigationTitle(document.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        showingDiffReview = true
                    }
                    .disabled(!isModified || isSaving)
                }
            }
        }
        .sheet(isPresented: $showingDiffReview) {
            MobileFileDiffReviewSheet(
                path: document.remotePath,
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
    }

    private func save() {
        saveError = nil
        isSaving = true

        Task { @MainActor in
            do {
                let backup = try await MobileSafeConfigSave.prepare(
                    connectionId: document.connectionId,
                    remotePath: document.remotePath,
                    fileName: document.fileName
                )
                try await onSave(content)
                if let validation = try await MobileSafeConfigSave.validate(
                    connectionId: document.connectionId,
                    backup: backup
                ) {
                    safetyMessage = "\(validation.title) passed. Backup: \(backup.backupPath)"
                } else {
                    safetyMessage = "Backup created: \(backup.backupPath)"
                }
                originalContent = content
                isSaving = false
                showingDiffReview = false
                MobileActivityLogStore.shared.record(
                    title: "File saved",
                    detail: document.remotePath,
                    connectionId: document.connectionId,
                    systemImage: "doc.text",
                    severity: .ok
                )
                onSaved()
                dismiss()
            } catch {
                MobileActivityLogStore.shared.record(
                    title: "File save failed",
                    detail: document.remotePath,
                    connectionId: document.connectionId,
                    systemImage: "exclamationmark.triangle.fill",
                    severity: .critical
                )
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }

    private var editorStatusBar: some View {
        HStack(spacing: 12) {
            Label(document.syntax.displayName, systemImage: "curlybraces")
            Label("\(lineCount) lines", systemImage: "number")
            if isModified {
                Label("\(changedLineCount) changed", systemImage: "plus.forwardslash.minus")
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Label("Backup + review", systemImage: "checkmark.shield")
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 7)
        .background(Color(.systemGroupedBackground))
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
}

enum MobileFileSyntax: Equatable {
    case plain
    case shell
    case sql
    case systemd
    case yaml

    init(fileName: String) {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "sh":
            self = .shell
        case "sql":
            self = .sql
        case "service":
            self = .systemd
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
        case .systemd: return "systemd unit"
        case .yaml: return "YAML"
        }
    }
}

private struct MobileSyntaxTextView: UIViewRepresentable {
    @Binding var text: String
    let syntax: MobileFileSyntax
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, syntax: syntax)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .systemBackground
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.allowsEditingTextAttributes = false
        textView.isEditable = isEditable
        context.coordinator.applyHighlighting(to: textView, text: text)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.syntax = syntax
        textView.isEditable = isEditable

        if textView.text != text {
            context.coordinator.applyHighlighting(to: textView, text: text)
        } else {
            textView.typingAttributes = MobileSyntaxHighlighter.baseAttributes
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var syntax: MobileFileSyntax

        private var isApplyingHighlighting = false
        private var pendingHighlight: DispatchWorkItem?

        init(text: Binding<String>, syntax: MobileFileSyntax) {
            self.text = text
            self.syntax = syntax
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingHighlighting else { return }
            text.wrappedValue = textView.text
            scheduleHighlighting(for: textView)
        }

        func applyHighlighting(to textView: UITextView, text: String) {
            guard !isApplyingHighlighting else { return }
            isApplyingHighlighting = true

            let selectedRange = textView.selectedRange
            let contentOffset = textView.contentOffset
            textView.attributedText = MobileSyntaxHighlighter.attributedString(
                for: text,
                syntax: syntax
            )
            textView.selectedRange = clamp(selectedRange, in: textView.text)
            textView.contentOffset = contentOffset
            textView.typingAttributes = MobileSyntaxHighlighter.baseAttributes

            isApplyingHighlighting = false
        }

        private func scheduleHighlighting(for textView: UITextView) {
            pendingHighlight?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyHighlighting(to: textView, text: textView.text)
            }
            pendingHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        private func clamp(_ range: NSRange, in text: String) -> NSRange {
            let length = (text as NSString).length
            guard range.location <= length else {
                return NSRange(location: length, length: 0)
            }
            let maxLength = max(0, length - range.location)
            return NSRange(location: range.location, length: min(range.length, maxLength))
        }
    }
}

private enum MobileSyntaxHighlighter {
    static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: UIColor.label
        ]
    }

    private static var commentAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: UIColor.secondaryLabel]
    }

    private static var keywordAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: UIColor.systemBlue]
    }

    private static var variableAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: UIColor.systemPurple]
    }

    private static var numberAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: UIColor.systemOrange]
    }

    private static var stringAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: UIColor.systemGreen]
    }

    static func attributedString(for text: String, syntax: MobileFileSyntax) -> NSAttributedString {
        let storage = NSMutableAttributedString(string: text, attributes: baseAttributes)
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        guard fullRange.length > 0 else { return storage }

        switch syntax {
        case .plain:
            return storage
        case .shell:
            highlightShell(storage, range: fullRange)
        case .sql:
            highlightSQL(storage, range: fullRange)
        case .systemd:
            highlightSystemd(storage, range: fullRange)
        case .yaml:
            highlightYAML(storage, range: fullRange)
        }

        return storage
    }

    private static func highlightShell(_ storage: NSMutableAttributedString, range: NSRange) {
        applyRegex(
            #"(?<![A-Za-z0-9_])(?:if|then|else|elif|fi|for|while|until|do|done|case|esac|function|in|select|time|coproc|return|exit|export|local|readonly|declare|typeset|source|alias|unalias|trap|shift|test)(?![A-Za-z0-9_])"#,
            to: storage,
            range: range,
            attributes: keywordAttributes
        )
        applyRegex(
            #"\$\{[^}\n]+\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9#?*!@$-]"#,
            to: storage,
            range: range,
            attributes: variableAttributes
        )
        applyRegex(
            #""(?:\\.|[^"\\])*"|'[^'\n]*'"#,
            to: storage,
            range: range,
            attributes: stringAttributes
        )
        applyCommentHighlighting(to: storage)
    }

    private static func highlightSQL(_ storage: NSMutableAttributedString, range: NSRange) {
        applyRegex(
            #"(?<![A-Za-z0-9_])(?:add|all|alter|and|as|asc|begin|between|by|cascade|case|check|commit|constraint|create|cross|database|default|delete|desc|distinct|drop|else|end|exists|foreign|from|full|grant|group|having|if|in|index|inner|insert|into|is|join|key|left|like|limit|not|null|offset|on|or|order|outer|primary|procedure|references|returning|revoke|right|rollback|schema|select|sequence|set|table|then|trigger|truncate|union|unique|update|using|values|view|when|where|with)(?![A-Za-z0-9_])"#,
            to: storage,
            range: range,
            options: [.caseInsensitive],
            attributes: keywordAttributes
        )
        applyRegex(
            #"(?<![A-Za-z0-9_])-?\d+(?:\.\d+)?(?![A-Za-z0-9_])"#,
            to: storage,
            range: range,
            attributes: numberAttributes
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

    private static func highlightSystemd(_ storage: NSMutableAttributedString, range: NSRange) {
        applyRegex(
            #"(?m)^\[[A-Za-z0-9_. -]+\]"#,
            to: storage,
            range: range,
            attributes: keywordAttributes
        )
        applyRegex(
            #"(?m)^([A-Za-z][A-Za-z0-9]+)(=)"#,
            to: storage,
            range: range,
            captureGroup: 1,
            attributes: variableAttributes
        )
        applyRegex(
            #"(?<![A-Za-z0-9_])(?:true|false|yes|no|on|off|always|no|on-failure|simple|forking|oneshot|notify|idle)(?![A-Za-z0-9_])"#,
            to: storage,
            range: range,
            options: [.caseInsensitive],
            attributes: numberAttributes
        )
        applyRegex(
            #""(?:\\.|[^"\\])*"|'[^'\n]*'"#,
            to: storage,
            range: range,
            attributes: stringAttributes
        )
        applyCommentHighlighting(to: storage)
    }

    private static func highlightYAML(_ storage: NSMutableAttributedString, range: NSRange) {
        applyRegex(
            #"(?m)^([ \t-]*)([A-Za-z0-9_.-]+)([ \t]*:)"#,
            to: storage,
            range: range,
            captureGroup: 2,
            attributes: keywordAttributes
        )
        applyRegex(
            #"(?<![A-Za-z0-9_])[&*][A-Za-z0-9_-]+"#,
            to: storage,
            range: range,
            attributes: variableAttributes
        )
        applyRegex(
            #"(?<=[:\[, \t-])(?:true|false|null|~|-?\d+(?:\.\d+)?)(?=$|[,\] \t#])"#,
            to: storage,
            range: range,
            options: [.caseInsensitive],
            attributes: numberAttributes
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
        to storage: NSMutableAttributedString,
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

    private static func applyCommentHighlighting(to storage: NSMutableAttributedString) {
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

    private static func isWhitespace(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}

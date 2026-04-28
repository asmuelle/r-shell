import SwiftUI

/// Minimal text editor for remote files. Fetches content on open and
/// provides a Save button that writes back via the FFI layer.
struct FileEditView: View {
    @Environment(\.dismiss) private var dismiss
    let connectionId: String
    let path: String
    @State var content: String
    var onSave: (String) -> Void

    @State private var originalContent = ""
    @State private var isModified = false

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

                Button("Save") {
                    onSave(content)
                    originalContent = content
                    isModified = false
                }
                .disabled(!isModified)
                .keyboardShortcut("s", modifiers: .command)

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Editor area
            TextEditor(text: $content)
                .font(.system(size: 12, design: .monospaced))
                .disableAutocorrection(true)
                .onChange(of: content) { _ in
                    isModified = content != originalContent
                }
        }
        .frame(width: 560, height: 420)
        .onAppear {
            originalContent = content
        }
    }
}

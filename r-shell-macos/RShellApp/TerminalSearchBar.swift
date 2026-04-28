import SwiftUI
import OSLog

/// Search overlay for the terminal scrollback buffer.
///
/// SwiftTerm has no built-in search, so we provide a native SwiftUI search bar
/// that overlays the terminal. It uses SwiftTerm's `findSubstring` API to
/// search the scrollback buffer and highlight matches.
///
/// Keyboard: ⌘F to open, ↩/⇧↩ to cycle, Esc to close.
struct TerminalSearchBar: View {
    @Binding var query: String
    @Binding var isVisible: Bool
    var matchCount: Int
    var currentMatch: Int
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 11))

            TextField("Search terminal…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { onNext() }

            if !query.isEmpty {
                Text("\(currentMatch)/\(matchCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 32)

                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .help("Previous match (⇧↩)")

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .help("Next match (↩)")
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Close search (Esc)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
}
